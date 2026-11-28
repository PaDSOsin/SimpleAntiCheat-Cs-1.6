/*
 * Simple AntiCheat
 *
 * Server-side cheat detection for Counter-Strike 1.6 (AMX Mod X 1.8.2+).
 *
 * Checks:
 *   - client cvars: cheat cvars, protected values, trap cvar, query blocking
 *   - player model consistency
 *   - speedhack, fps limit, invalid pitch, spinbot
 *   - bhop / duck scripts, strafe helpers, non-keyboard movement, autostop
 *   - aim: snap, silent, smooth, mouse step (GCD), no-recoil, trigger, autofire
 *   - headshot ratio
 *
 * Every detection adds violation level (VL); the player is punished when VL
 * reaches ac_vl_kick. VL decays over time and is kept between sessions.
 *
 * 1.3:
 *   - #20 (fps): fps is measured against both usercmd msec and server real
 *     time (the lower value is used), so msec rounding at high fps no longer
 *     inflates it; default ac_fps_max raised from 105 to 1000 (high fps is
 *     allowed, only values a normal client cannot reach are flagged. 
 *     temporary commented, to change it later(kick on 100+ fps)).
 *   - #12 (nokeys): a move that is left over from a key that was really held
 *     (ESC menu / console / stuck key) is no longer counted as moving without
 *     keys, and frames with a frozen view (menu open) are skipped.
 *
 * 1.3.1:
 *   - #16 (gcd): a view kick that does not come from the mouse (being hit,
 *     especially in the head, or a fall) moves the client view without the
 *     mouse step; combined with own mouse movement those turns were counted as
 *     off-step and the player was kicked. GCD samples are now skipped while
 *     such a kick is active: from the hit until the punch angle has decayed,
 *     plus ac_gcd_hit seconds and the player's ping (0 = old behaviour).
 *
 * 1.3.2:
 *   - #24 (autostop): during freezetime (buy time) the player cannot move, so
 *     the client sends a zero move while W/A/S/D are held; this was counted as
 *     autostop and the player was kicked. The freeze period is now tracked by
 *     the round events (new round -> Round_Start) and autostop is not checked
 *     while it lasts, nor while the player's speed is locked (maxspeed <= 1 or
 *     FL_FROZEN). After the unlock the check stays off for AUTOSTOP_UNLOCK
 *     seconds plus the player's ping, because the client still moves with the
 *     old (locked) speed until it receives the new one.
 *
 * Commands:
 *   amx_acstats [name|#userid]           - VL and sample counters
 *   amx_acdebug <name|#userid> [seconds] - dump usercmds to the debug log
 *   amx_acreset <name|#userid>           - clear VL and samples
 *
 * Files:
 *   configs/simple_anticheat.cfg - cvars
 *   configs/simple_anticheat.ini - cheat / protected cvar lists
 *   logs/anticheat.log           - detections
 *   logs/ac_debug.log            - frame dumps
 */
#include <amxmodx>
#include <amxmisc>
#include <fakemeta>
#include <hlsdk_const>
#include <nvault>
#define PLUGIN  "Simple AntiCheat"
#define VERSION "1.3.2"
#define AUTHOR  "Rust"
// Player slots and task id bases
#define MAXP              33
#define TASK_CHECK        5100
#define TASK_SECOND       5200
#define TASK_QUERY        5300
#define TASK_VERIFY       5400
#define TASK_KICK         5500
// Files
#define LOG_FILE          "anticheat.log"
#define DEBUG_FILE        "ac_debug.log"
#define VAULT_NAME        "simple_anticheat"
#define CFG_FILE          "simple_anticheat.cfg"
#define LIST_FILE         "simple_anticheat.ini"
// Cvar lists, logging and admin notifications
#define MAX_LIST          64
#define LOG_ONLY_COOLDOWN 30.0
#define ADMIN_MSG_DELAY   3.0
#define ADMIN_NOTIFY_FLAG ADMIN_BAN
// Jump / duck script detection
#define BHOP_CHAIN_MS     100
#define JUMP_MIN_AIR_MS   80
#define JUMP_EXACT_MSEC   12
#define JUMP_TAP_MSEC     25
#define JUMP_TAP_FRAMES   3
#define SPAM_MIN_PRESSES  4
#define BTN_JUMP          0
#define BTN_DUCK          1
// Autofire
#define AUTOFIRE_MAX_MSEC 4
#define AUTOFIRE_MAX_GAP  400
#define AUTOFIRE_MAX_HOLD 2
// Timing
#define SPAWN_GRACE       1.5
#define AUTOSTOP_UNLOCK   1.0
#define CHECK_JITTER      0.3
#define VERIFY_TIMEOUT    6.0
// Move vector, mouse step (GCD) and recoil tolerances
#define VECTOR_MIN_MOVE   30.0
#define VECTOR_TOLERANCE  0.01
#define GCD_TOLERANCE     0.006
#define GCD_MIN_STEP      0.025
#define RECOIL_MIN_PUNCH  0.1
// View kick from a hit / fall: punch growth that starts the GCD pause and the
// punch size below which the kick counts as decayed
#define HIT_PUNCH_MIN     0.05
#define HIT_PUNCH_IDLE    0.01
#define RECOIL_TOLERANCE  0.02
// Line of sight: how many see-through entities a trace may skip
#define TRACE_PASSES      3
// Ring buffer sizes
#define RING              64
#define SEC_RING          30
#define FRAMES            64
#define STREAMS           22
// Event streams (hits / total inside a time window)
#define ST_BHOP           0
#define ST_GSTRAFE        1
#define ST_STRAFE         2
#define ST_SNAP           3
#define ST_NOKEYS         4
#define ST_VECTOR         5
#define ST_FASTSW         6
#define ST_GCD            7
#define ST_RECOIL         8
#define ST_TRIGGER        9
#define ST_AUTOFIRE       10
#define ST_BHOP_EXACT     11
#define ST_BHOP_TAP       12
#define ST_BHOP_SPAM      13
#define ST_DD_EXACT       14
#define ST_DD_TAP         15
#define ST_DD_SPAM        16
#define ST_SILENT         17
#define ST_SMOOTH         18
#define ST_HS             19
#define ST_AUTOSTOP       20
#define ST_SILENT_STRONG  21
// Position history used for lag compensation
#define RW_SIZE           64
#define RW_STEP           0.008
// Aim analysis
#define AIM_NONE          999.0
#define AIM_MAX_ERR       30.0
#define SMOOTH_MIN_MAG    0.08
#define SMOOTH_QUANT      0.008
#define SMOOTH_K_MIN      0.30
#define SMOOTH_K_MAX      0.95
// Movement state of a usercmd
#define MOVE_GROUND       0
#define MOVE_AIR          1
#define MOVE_OTHER        2
// Client cvars queried from players
#define CL_FWD            0
#define CL_BACK           1
#define CL_SIDE           2
#define CL_SENS           3
#define CL_MYAW           4
#define CL_MFILTER        5
#define CL_MACCEL         6
#define CL_INTERP         7
#define CL_TOTAL          8
// Detections that re-check client settings before punishing
#define VERIFY_GCD        0
#define VERIFY_VECTOR     1
#define VERIFY_SILENT     2
#define VERIFY_KINDS      3
// Weapon groups
#define BITS_NOGUN  ((1<<CSW_KNIFE)|(1<<CSW_HEGRENADE)|(1<<CSW_FLASHBANG)|(1<<CSW_SMOKEGRENADE)|(1<<CSW_C4))
#define BITS_PISTOL ((1<<CSW_GLOCK18)|(1<<CSW_USP)|(1<<CSW_P228)|(1<<CSW_DEAGLE)|(1<<CSW_ELITE)|(1<<CSW_FIVESEVEN))
#define BITS_AUTO   ((1<<CSW_MP5NAVY)|(1<<CSW_TMP)|(1<<CSW_P90)|(1<<CSW_MAC10)|(1<<CSW_UMP45)|(1<<CSW_AK47)|(1<<CSW_M4A1)|(1<<CSW_GALIL)|(1<<CSW_FAMAS)|(1<<CSW_SG552)|(1<<CSW_AUG)|(1<<CSW_M249))
// Cached cvar access. The Float: override is required: a cell indexed
// with an enum constant takes the tag of that constant, not of the array.
#define CVF(%1) (Float:g_fCv[%1])
#define CVI(%1) (g_iCv[%1])
// Detection ids: the number shown in "Detect #N"
enum
{
    DETECT_NONE = 0,
    DETECT_CHEAT_CVAR,      // #1
    DETECT_BAD_VALUE,       // #2
    DETECT_FILE,            // #3
    DETECT_SPEED,           // #4
    DETECT_NO_QUERY,        // #5
    DETECT_BHOP,            // #6
    DETECT_PITCH,           // #7
    DETECT_SPIN,            // #8
    DETECT_SNAP,            // #9
    DETECT_STRAFE,          // #10
    DETECT_GSTRAFE,         // #11
    DETECT_NOKEYS,          // #12
    DETECT_VECTOR,          // #13
    DETECT_FASTSTRAFE,      // #14
    DETECT_TRAP,            // #15
    DETECT_GCD,             // #16
    DETECT_NORECOIL,        // #17
    DETECT_TRIGGER,         // #18
    DETECT_AUTOFIRE,        // #19
    DETECT_FPS,             // #20
    DETECT_SILENT,          // #21
    DETECT_SMOOTH,          // #22
    DETECT_HEADSHOT,        // #23
    DETECT_AUTOSTOP,        // #24
    DETECT_TOTAL
};
// Cvar indexes
enum
{
    CV_FIRST_CHECK = 0,
    CV_INTERVAL,
    CV_IMMUNITY,
    CV_NOTIFY,
    CV_LOG_WARN,
    CV_SNAPSHOT,
    CV_CONSOLE,
    CV_WINDOW,
    CV_SEC_WINDOW,
    CV_VL_KICK,
    CV_VL_DECAY,
    CV_VL_SCALE,
    CV_REMEMBER,
    CV_VERIFY,
    CV_LAG_PING,
    CV_LAG_LOSS,
    CV_SPEED,
    CV_SPEED_LIMIT,
    CV_SPEED_RATIO,
    CV_SPEED_WARNS,
    CV_SPEED_VL,
    CV_QUERY,
    CV_QUERY_TIMEOUT,
    CV_QUERY_FAILS,
    CV_JUMP_WINDOW,
    CV_BHOP,
    CV_BHOP_JUMPS,
    CV_BHOP_PERCENT,
    CV_BHOP_EXACT_JUMPS,
    CV_BHOP_EXACT_PERCENT,
    CV_BHOP_TAP_JUMPS,
    CV_BHOP_TAP_PERCENT,
    CV_BHOP_SPAM_JUMPS,
    CV_BHOP_SPAM_PERCENT,
    CV_BHOP_VL,
    CV_PITCH,
    CV_PITCH_LIMIT,
    CV_PITCH_WARNS,
    CV_SPIN,
    CV_SPIN_LIMIT,
    CV_SPIN_WARNS,
    CV_SPIN_VL,
    CV_SNAP,
    CV_SNAP_ANGLE,
    CV_SNAP_RATIO,
    CV_SNAP_FOV,
    CV_SNAP_COUNT,
    CV_SNAP_WINDOW,
    CV_SNAP_VL,
    CV_STRAFE,
    CV_STRAFE_SAMPLES,
    CV_STRAFE_PERCENT,
    CV_STRAFE_MINTURN,
    CV_STRAFE_VL,
    CV_GSTRAFE,
    CV_GSTRAFE_DUCKS,
    CV_GSTRAFE_PERCENT,
    CV_GSTRAFE_EXACT_DUCKS,
    CV_GSTRAFE_EXACT_PERCENT,
    CV_GSTRAFE_TAP_DUCKS,
    CV_GSTRAFE_TAP_PERCENT,
    CV_GSTRAFE_SPAM_DUCKS,
    CV_GSTRAFE_SPAM_PERCENT,
    CV_GSTRAFE_VL,
    CV_NOKEYS,
    CV_NOKEYS_SAMPLES,
    CV_NOKEYS_PERCENT,
    CV_NOKEYS_VL,
    CV_VECTOR,
    CV_VECTOR_SAMPLES,
    CV_VECTOR_PERCENT,
    CV_VECTOR_VL,
    CV_FS,
    CV_FS_MS,
    CV_FS_SAMPLES,
    CV_FS_PERCENT,
    CV_FS_VL,
    CV_TRAP,
    CV_GCD,
    CV_GCD_SAMPLES,
    CV_GCD_PERCENT,
    CV_GCD_VL,
    CV_GCD_CONTEXT,
    CV_GCD_FOV,
    CV_GCD_HIT,
    CV_RECOIL,
    CV_RECOIL_SAMPLES,
    CV_RECOIL_PERCENT,
    CV_RECOIL_VL,
    CV_TRIGGER,
    CV_TRIGGER_MS,
    CV_TRIGGER_IDLE,
    CV_TRIGGER_STILL,
    CV_TRIGGER_SAMPLES,
    CV_TRIGGER_PERCENT,
    CV_TRIGGER_VL,
    CV_AUTOFIRE,
    CV_AUTOFIRE_SAMPLES,
    CV_AUTOFIRE_PERCENT,
    CV_AUTOFIRE_VL,
    CV_FPS,
    CV_FPS_MAX,
    CV_FPS_WARNS,
    CV_FPS_VL,
    CV_REWIND,
    CV_HIT_RADIUS,
    CV_AIM_TARGET,
    CV_SILENT,
    CV_SILENT_ANGLE,
    CV_SILENT_MIN,
    CV_SILENT_RETURN,
    CV_SILENT_FOV,
    CV_SILENT_COUNT,
    CV_SILENT_WINDOW,
    CV_SILENT_VL,
    CV_SILENT_INSTANT,
    CV_SILENT_EXACT,
    CV_SILENT_FOCUS,
    CV_SILENT_MSEC,
    CV_SMOOTH,
    CV_SMOOTH_FRAMES,
    CV_SMOOTH_TOL,
    CV_SMOOTH_FOV,
    CV_SMOOTH_COUNT,
    CV_SMOOTH_WINDOW,
    CV_SMOOTH_VL,
    CV_HS,
    CV_HS_KILLS,
    CV_HS_PERCENT,
    CV_HS_WINDOW,
    CV_HS_VL,
    CV_AUTOSTOP,
    CV_AUTOSTOP_COUNT,
    CV_AUTOSTOP_WINDOW,
    CV_AUTOSTOP_VL,
    CV_PUNISH,
    CV_BAN_TIME,
    CV_ADMIN_NOTIFY,
    CV_TOTAL
};
// Default lists, used when simple_anticheat.ini is missing
new const g_szCheatCvarsDef[][] =
{
    "ac_example_cheat_cvar_1",
    "ac_example_cheat_cvar_2"
};
new const g_szProtCvarsDef[][] =
{
    "r_fullbright",
    "gl_wireframe",
    "r_drawentities",
    "gl_monolights"
};
new const Float:g_fProtAllowedDef[] =
{
    0.0,
    0.0,
    1.0,
    0.0
};
// Client cvars and their stock values
new const g_szClientCvars[CL_TOTAL][] =
{
    "cl_forwardspeed",
    "cl_backspeed",
    "cl_sidespeed",
    "sensitivity",
    "m_yaw",
    "m_filter",
    "m_customaccel",
    "ex_interp"
};
new const Float:g_fClientDefault[CL_TOTAL] =
{
    400.0, 400.0, 400.0, 0.0, 0.022, 0.0, 0.0, 0.1
};
// Forward / side move ratios that a keyboard can produce
new const Float:g_fKeyRatios[] =
{
    0.25, 0.3333, 0.5, 0.6667, 0.75, 1.0, 1.3333, 1.5, 2.0, 3.0, 4.0
};
// Player models that must match the server copy
new const g_szModels[][] =
{
    "models/player/arctic/arctic.mdl",
    "models/player/gign/gign.mdl",
    "models/player/gsg9/gsg9.mdl",
    "models/player/guerilla/guerilla.mdl",
    "models/player/leet/leet.mdl",
    "models/player/sas/sas.mdl",
    "models/player/terror/terror.mdl",
    "models/player/urban/urban.mdl",
    "models/player/vip/vip.mdl"
};
// Lookup tables for the jump / duck script checks (index: BTN_*)
new const g_iBtnBit[2]       = { IN_JUMP, IN_DUCK };
new const g_iBtnFlag[2]      = { DETECT_BHOP, DETECT_GSTRAFE };
new const g_iBtnOn[2]        = { CV_BHOP, CV_GSTRAFE };
new const g_iBtnStPerfect[2] = { ST_BHOP, ST_GSTRAFE };
new const g_iBtnStExact[2]   = { ST_BHOP_EXACT, ST_DD_EXACT };
new const g_iBtnStTap[2]     = { ST_BHOP_TAP, ST_DD_TAP };
new const g_iBtnStSpam[2]    = { ST_BHOP_SPAM, ST_DD_SPAM };
new const g_iBtnCvPerfN[2]   = { CV_BHOP_JUMPS, CV_GSTRAFE_DUCKS };
new const g_iBtnCvPerfP[2]   = { CV_BHOP_PERCENT, CV_GSTRAFE_PERCENT };
new const g_iBtnCvExactN[2]  = { CV_BHOP_EXACT_JUMPS, CV_GSTRAFE_EXACT_DUCKS };
new const g_iBtnCvExactP[2]  = { CV_BHOP_EXACT_PERCENT, CV_GSTRAFE_EXACT_PERCENT };
new const g_iBtnCvTapN[2]    = { CV_BHOP_TAP_JUMPS, CV_GSTRAFE_TAP_DUCKS };
new const g_iBtnCvTapP[2]    = { CV_BHOP_TAP_PERCENT, CV_GSTRAFE_TAP_PERCENT };
new const g_iBtnCvSpamN[2]   = { CV_BHOP_SPAM_JUMPS, CV_GSTRAFE_SPAM_DUCKS };
new const g_iBtnCvSpamP[2]   = { CV_BHOP_SPAM_PERCENT, CV_GSTRAFE_SPAM_PERCENT };
new const g_szBtnName[2][]   = { "bhop", "dd/gstrafe" };
// Lookup tables for settings verification (index: VERIFY_*)
new const g_iVerifyFlag[VERIFY_KINDS]   = { DETECT_GCD, DETECT_VECTOR, DETECT_SILENT };
new const g_iVerifyStream[VERIFY_KINDS] = { ST_GCD, ST_VECTOR, ST_SILENT_STRONG };
new const g_iVerifyFirst[VERIFY_KINDS]  = { CL_SENS, CL_FWD, CL_FWD };
new const g_iVerifyLast[VERIFY_KINDS]   = { CL_MACCEL, CL_SIDE, CL_MACCEL };
// Cvar lists
new g_szCheatCvars[MAX_LIST][32];
new g_iCheatCount;
new g_szProtCvars[MAX_LIST][32];
new Float:g_fProtAllowed[MAX_LIST];
new g_iProtCount;
// Cvars: pointers and values cached once per second
new g_pCvar[CV_TOTAL];
new Float:g_fCv[CV_TOTAL];
new g_iCv[CV_TOTAL];
new g_pcBanCmd;
new g_iWeightCv[DETECT_TOTAL];
// Server state
new g_hVault = INVALID_HANDLE;
new g_iMaxPlayers;
new g_szLogsDir[96];
new g_iLastTick;
new g_iTickMs = 1000;
new bool:g_bHitch;
new bool:g_bFreezeTime;
new Float:g_fFreezeEnd;
new Float:g_fFreezeMax;
new g_pFreezeTime;
// Player state
new bool:g_bKicked[MAXP];
new bool:g_bIgnore[MAXP];
new bool:g_bWasAlive[MAXP];
new bool:g_bLag[MAXP];
new Float:g_fGraceUntil[MAXP];
new Float:g_fSpeedLockUntil[MAXP];
new Float:g_fDebugUntil[MAXP];
new Float:g_fLastDump[MAXP];
new Float:g_fLastAdminMsg[MAXP];
new Float:g_fLogOnlyUntil[MAXP][DETECT_TOTAL];
new g_szKey[MAXP][48];
// Violation levels
new Float:g_fVL[MAXP][DETECT_TOTAL];
new Float:g_fMaxVL[MAXP][DETECT_TOTAL];
new Float:g_fCooldown[MAXP][DETECT_TOTAL];
// Counters of the current second
new g_iMsec[MAXP];
new g_iFrames[MAXP];
new g_iClock[MAXP];
new g_iFrameNo[MAXP];
new Float:g_fYawSum[MAXP];
new g_iPitchCount[MAXP];
new Float:g_fLastBadPitch[MAXP];
// Per-second history
new g_iSecMsec[MAXP][SEC_RING];
new g_iSecReal[MAXP][SEC_RING];
new g_iSecFrames[MAXP][SEC_RING];
new Float:g_fSecYaw[MAXP][SEC_RING];
new g_iSecPitch[MAXP][SEC_RING];
new bool:g_bSecAlive[MAXP][SEC_RING];
new bool:g_bSecLag[MAXP][SEC_RING];
new g_iSecHead[MAXP];
// Event streams
new Float:g_fEvTime[MAXP][STREAMS][RING];
new bool:g_bEvHit[MAXP][STREAMS][RING];
new g_iEvHead[MAXP][STREAMS];
new g_iEvFill[MAXP][STREAMS];
// Last usercmd frames (debug snapshot)
new g_iFrMove[MAXP][FRAMES];
new g_iFrMsec[MAXP][FRAMES];
new Float:g_fFrPitch[MAXP][FRAMES];
new Float:g_fFrYaw[MAXP][FRAMES];
new Float:g_fFrF[MAXP][FRAMES];
new Float:g_fFrS[MAXP][FRAMES];
new g_iFrBtn[MAXP][FRAMES];
new g_iFrHead[MAXP];
new g_iFrFill[MAXP];
// Cvar queries
new g_iAnswered[MAXP];
new g_iQueryFails[MAXP];
new Float:g_fCl[MAXP][CL_TOTAL];
// Settings verification
new g_iVerifyLeft[MAXP][VERIFY_KINDS];
new bool:g_bVerifyChanged[MAXP][VERIFY_KINDS];
new Float:g_fVerifyMult[MAXP][VERIFY_KINDS];
new g_szVerifyDetail[MAXP][VERIFY_KINDS][256];
// Ground state and jump / duck buttons
new g_iGroundFrames[MAXP];
new g_iGroundMs[MAXP];
new g_iAirMs[MAXP];
new g_iLastAirMs[MAXP];
new g_iLastButtons[MAXP];
new g_iBtnHold[MAXP][2];
new g_iBtnAir[MAXP][2];
new g_iBtnAirLand[MAXP][2];
new g_iBtnAirLast[MAXP][2];
new g_iBtnSpamInt[MAXP][2];
new g_iBtnSpamHold[MAXP][2];
new g_iBtnSpamLand[MAXP][2];
new g_iBtnSpamPrev[MAXP][2];
new bool:g_bBtnSampled[MAXP][2];
new bool:g_bBtnPend[MAXP][2];
new g_iBtnPendGround[MAXP][2];
new g_iBtnPendAir[MAXP][2];
// Move without keys: per axis (NK_FWD / NK_SIDE) the move sign that was
// last backed by a held key, 0 = none
#define NK_FWD            0
#define NK_SIDE           1
new g_iNkSign[MAXP][2];
// View angle history (A = two frames ago, B = previous frame)
new Float:g_fAngA[MAXP][2];
new Float:g_fAngB[MAXP][2];
new Float:g_fDeltaA[MAXP];
new Float:g_fDeltaB[MAXP];
new g_iAngHist[MAXP];
new g_iLastMsec[MAXP];
new g_iLastMsecA[MAXP];
// Strafe checks
new g_iLastMouseDir[MAXP];
new Float:g_fSegYaw[MAXP];
new g_iLastSideDir[MAXP];
new g_iLastSideSign[MAXP];
new g_iHoldMs[MAXP];
// Recoil, trigger and autofire
new Float:g_fLastPunch[MAXP];
new bool:g_bHasPunch[MAXP];
// View kick from a hit / fall (GCD pause)
new Float:g_fHitUntil[MAXP];
new Float:g_fHitPunch[MAXP];
new bool:g_bOnTarget[MAXP];
new bool:g_bTargetIdle[MAXP];
new g_iTargetStart[MAXP];
new g_iLastAttack[MAXP];
new g_iLastPress[MAXP];
new g_iLastPressFrame[MAXP];
new g_iPrevInterval[MAXP];
new g_iPrevIntFrames[MAXP];
new g_iPrevHold[MAXP];
new g_iAttackHold[MAXP];
new g_iAttackLastHold[MAXP];
// Ping and aim error / move history (A and B as above)
new g_iPing[MAXP];
new Float:g_fErrA[MAXP];
new Float:g_fErrB[MAXP];
new Float:g_fMvA[MAXP][2];
new Float:g_fMvB[MAXP][2];
// Smooth aim
new Float:g_fSmPrevMag[MAXP];
new Float:g_fSmPrevDp[MAXP];
new Float:g_fSmPrevDy[MAXP];
new Float:g_fSmK[MAXP];
new Float:g_fSmT[MAXP];
new bool:g_bSmHaveK[MAXP];
new g_iSmRun[MAXP];
new Float:g_fSmKMin[MAXP];
new Float:g_fSmKMax[MAXP];
new g_iSmOn[MAXP];
new g_iSmOff[MAXP];
new Float:g_fSmStartErr[MAXP];
// Player snapshot: alive / team cache and position history
new Float:g_fRwLast;
new bool:g_bAlive[MAXP];
new g_iTeam[MAXP];
new Float:g_fRwTime[MAXP][RW_SIZE];
new Float:g_fRwOrg[MAXP][RW_SIZE][3];
new bool:g_bRwDuck[MAXP][RW_SIZE];
new g_iRwHead[MAXP];
new g_iRwFill[MAXP];
// Helpers
// Registers a cvar and stores its pointer under the CV_* index.
RegCvar(idx, const name[], const def[])
{
    g_pCvar[idx] = register_cvar(name, def);
}
// Reads every cvar once; the checks only use the cached values.
CacheCvars()
{
    for (new i = 0; i < CV_TOTAL; i++)
    {
        g_fCv[i] = get_pcvar_float(g_pCvar[i]);
        g_iCv[i] = floatround(g_fCv[i]);
    }
}
IntAbs(v)
{
    return (v < 0) ? -v : v;
}
// Wraps an angle into [-180, 180]; garbage input becomes 9999.
Float:NormalizeAngle(Float:a)
{
    if (floatabs(a) > 100000.0)
        return 9999.0;
    return a - 360.0 * float(floatround(a / 360.0));
}
// Angular distance between two (pitch, yaw) pairs, degrees.
Float:AngleDist(Float:p1, Float:y1, Float:p2, Float:y2)
{
    new Float:dp = NormalizeAngle(p1 - p2);
    new Float:dy = NormalizeAngle(y1 - y2);
    return floatsqroot(dp * dp + dy * dy);
}
// Strafe direction of a side move: 1 = left, -1 = right, 0 = none.
SideDir(Float:sidemove)
{
    if (sidemove < 0.0)
        return 1;
    if (sidemove > 0.0)
        return -1;
    return 0;
}
bool:WeaponIn(weapon, bits)
{
    return (weapon > 0 && weapon < 32 && (bits & (1 << weapon)));
}
bool:IsImmune(id)
{
    return (CVI(CV_IMMUNITY) && (get_user_flags(id) & ADMIN_IMMUNITY));
}
// Eye position: origin + view offset.
GetEye(id, Float:out[3])
{
    new Float:ofs[3];
    pev(id, pev_origin, out);
    pev(id, pev_view_ofs, ofs);
    for (new i = 0; i < 3; i++)
        out[i] += ofs[i];
}
// Logging and notifications
// Writes a line to a log file. With ac_console 0 the file is written
// directly, so the line is not echoed to the server console.
LogFile(const file[], const fmt[], any:...)
{
    new msg[512];
    vformat(msg, charsmax(msg), fmt, 3);
    if (CVI(CV_CONSOLE))
    {
        log_to_file(file, "%s", msg);
        return;
    }
    new path[128], date[32], line[560];
    formatex(path, charsmax(path), "%s/%s", g_szLogsDir, file);
    get_time("%m/%d/%Y - %H:%M:%S", date, charsmax(date));
    formatex(line, charsmax(line), "L %s: %s^n", date, msg);
    new f = fopen(path, "at");
    if (f)
    {
        fputs(f, line);
        fclose(f);
    }
}
// One usercmd as text for the debug log.
FormatFrame(out[], len, moveType, msec, Float:pitch, Float:yaw, Float:fmove, Float:smove, buttons)
{
    new szMove[8];
    if (moveType == MOVE_AIR)
        copy(szMove, charsmax(szMove), "air");
    else if (moveType == MOVE_GROUND)
        copy(szMove, charsmax(szMove), "ground");
    else
        copy(szMove, charsmax(szMove), "other");
    formatex(out, len, "%s ms=%d p=%.3f y=%.3f f=%.0f s=%.0f keys=%c%c%c%c%c%c%c",
        szMove, msec, pitch, yaw, fmove, smove,
        (buttons & IN_FORWARD)   ? 'W' : '-',
        (buttons & IN_MOVELEFT)  ? 'A' : '-',
        (buttons & IN_BACK)      ? 'S' : '-',
        (buttons & IN_MOVERIGHT) ? 'D' : '-',
        (buttons & IN_JUMP)      ? 'J' : '-',
        (buttons & IN_DUCK)      ? 'C' : '-',
        (buttons & IN_ATTACK)    ? 'F' : '-');
}
// Stores the usercmd in the per-player frame ring.
RecordFrame(id, moveType, msec, Float:pitch, Float:yaw, Float:fmove, Float:smove, buttons)
{
    new h = g_iFrHead[id];
    g_iFrMove[id][h]  = moveType;
    g_iFrMsec[id][h]  = msec;
    g_fFrPitch[id][h] = pitch;
    g_fFrYaw[id][h]   = yaw;
    g_fFrF[id][h]     = fmove;
    g_fFrS[id][h]     = smove;
    g_iFrBtn[id][h]   = buttons;
    g_iFrHead[id] = (h + 1) % FRAMES;
    if (g_iFrFill[id] < FRAMES)
        g_iFrFill[id]++;
}
// Dumps the last frames of a player to the debug log (once per second at most).
DumpFrames(id, const prefix[])
{
    if (!CVI(CV_SNAPSHOT) || g_iFrFill[id] == 0)
        return;
    new Float:now = get_gametime();
    if (now - g_fLastDump[id] < 1.0)
        return;
    g_fLastDump[id] = now;
    new name[32], line[160];
    get_user_name(id, name, charsmax(name));
    LogFile(DEBUG_FILE, "==== %s %s: last %d frames ====", prefix, name, g_iFrFill[id]);
    new start = (g_iFrHead[id] - g_iFrFill[id] + FRAMES) % FRAMES;
    new f;
    for (new i = 0; i < g_iFrFill[id]; i++)
    {
        f = (start + i) % FRAMES;
        FormatFrame(line, charsmax(line), g_iFrMove[id][f], g_iFrMsec[id][f], g_fFrPitch[id][f],
            g_fFrYaw[id][f], g_fFrF[id][f], g_fFrS[id][f], g_iFrBtn[id][f]);
        LogFile(DEBUG_FILE, "%s", line);
    }
}
LogLine(id, const prefix[], const detail[])
{
    new name[32], auth[35], ip[16];
    get_user_name(id, name, charsmax(name));
    get_user_authid(id, auth, charsmax(auth));
    get_user_ip(id, ip, charsmax(ip), 1);
    LogFile(LOG_FILE, "%s %s <%s> <%s> | %s", prefix, name, auth, ip, detail);
}
NotifyKick(id, flag, bool:ban)
{
    if (!CVI(CV_NOTIFY))
        return;
    new name[32];
    get_user_name(id, name, charsmax(name));
    client_print(0, print_chat, "[AC] %s %s: Detect #%d", name, ban ? "banned" : "kicked", flag);
}
// Chat message to online admins, rate limited per player.
NotifyAdmins(id, const fmt[], any:...)
{
    if (!CVI(CV_ADMIN_NOTIFY))
        return;
    new Float:now = get_gametime();
    if (now < g_fLastAdminMsg[id])
        return;
    g_fLastAdminMsg[id] = now + ADMIN_MSG_DELAY;
    new msg[160], name[32];
    vformat(msg, charsmax(msg), fmt, 3);
    get_user_name(id, name, charsmax(name));
    new players[32], num, admin;
    get_players(players, num, "ch");
    for (new i = 0; i < num; i++)
    {
        admin = players[i];
        if (admin != id && (get_user_flags(admin) & ADMIN_NOTIFY_FLAG))
            client_print(admin, print_chat, "[AC] %s: %s", name, msg);
    }
}
// Punishment
// Makes a string safe to pass into a server command.
SafeCmdArg(str[])
{
    for (new i = 0; str[i]; i++)
    {
        if (str[i] == ';' || str[i] == '"' || str[i] == 39 || str[i] < ' ')
            str[i] = '_';
    }
}
// Bans with ac_ban_cmd, or with banid / addip when the template is empty.
BanPlayer(id, flag, const reason[])
{
    new userid = get_user_userid(id);
    new minutes = CVI(CV_BAN_TIME);
    if (minutes < 0)
        minutes = 0;
    new auth[35], ip[16], tpl[192];
    get_user_authid(id, auth, charsmax(auth));
    get_user_ip(id, ip, charsmax(ip), 1);
    SafeCmdArg(auth);
    SafeCmdArg(ip);
    get_pcvar_string(g_pcBanCmd, tpl, charsmax(tpl));
    trim(tpl);
    if (tpl[0])
    {
        new num[12];
        num_to_str(userid, num, charsmax(num));
        replace_all(tpl, charsmax(tpl), "[userid]", num);
        num_to_str(minutes, num, charsmax(num));
        replace_all(tpl, charsmax(tpl), "[time]", num);
        replace_all(tpl, charsmax(tpl), "[authid]", auth);
        replace_all(tpl, charsmax(tpl), "[ip]", ip);
        replace_all(tpl, charsmax(tpl), "[reason]", reason);
        server_cmd("%s", tpl);
    }
    else if (IsUniqueAuth(auth))
    {
        server_cmd("banid %d %s kick", minutes, auth);
        if (minutes == 0)
            server_cmd("writeid");
    }
    else
    {
        server_cmd("addip %d %s", minutes, ip);
        if (minutes == 0)
            server_cmd("writeip");
    }
    new param[2];
    param[0] = userid;
    param[1] = flag;
    remove_task(TASK_KICK + id);
    set_task(0.5, "task_Kick", TASK_KICK + id, param, 2);
}
public task_Kick(const param[], taskid)
{
    new id = taskid - TASK_KICK;
    if (id < 1 || id >= MAXP || !is_user_connected(id) || get_user_userid(id) != param[0])
        return;
    server_cmd("kick #%d ^"Detect #%d^"", param[0], param[1]);
}
// Kicks or bans according to ac_punish; immune players and log-only mode
// are just logged. Returns true when the player was actually punished.
bool:Punish(id, flag, const detail[])
{
    if (g_bKicked[id])
        return false;
    new prefix[32];
    new mode = CVI(CV_PUNISH);
    new bool:immune = IsImmune(id);
    if (immune || mode <= 0)
    {
        g_fVL[id][flag] = 0.0;
        new Float:now = get_gametime();
        if (now < g_fLogOnlyUntil[id][flag])
            return false;
        g_fLogOnlyUntil[id][flag] = now + LOG_ONLY_COOLDOWN;
        formatex(prefix, charsmax(prefix), immune ? "[Immune #%d]" : "[LogOnly #%d]", flag);
        LogLine(id, prefix, detail);
        DumpFrames(id, prefix);
        NotifyAdmins(id, "Detect #%d (%s)", flag, immune ? "immune" : "log only");
        return false;
    }
    g_bKicked[id] = true;
    new bool:ban = (mode >= 2);
    formatex(prefix, charsmax(prefix), ban ? "[Ban #%d]" : "[Detect #%d]", flag);
    LogLine(id, prefix, detail);
    DumpFrames(id, prefix);
    NotifyKick(id, flag, ban);
    SaveVL(id);
    new reason[24];
    formatex(reason, charsmax(reason), "Detect #%d", flag);
    if (ban)
        BanPlayer(id, flag, reason);
    else
        server_cmd("kick #%d ^"%s^"", get_user_userid(id), reason);
    return true;
}
// Adds the detection weight to the player VL and punishes at ac_vl_kick.
AddViolation(id, flag, const detail[], Float:cooldown, Float:mult = 1.0)
{
    if (g_bKicked[id] || g_iWeightCv[flag] < 0)
        return;
    new Float:now = get_gametime();
    if (now < g_fCooldown[id][flag])
        return;
    g_fCooldown[id][flag] = now + cooldown;
    new Float:add = CVF(g_iWeightCv[flag]) * mult;
    g_fVL[id][flag] += add;
    if (g_fVL[id][flag] > g_fMaxVL[id][flag])
        g_fMaxVL[id][flag] = g_fVL[id][flag];
    new Float:kick = CVF(CV_VL_KICK);
    new full[320];
    formatex(full, charsmax(full), "%s | +%.0f VL %.0f/%.0f", detail, add, g_fVL[id][flag], kick);
    if (g_fVL[id][flag] >= kick)
    {
        Punish(id, flag, full);
        return;
    }
    new prefix[24];
    formatex(prefix, charsmax(prefix), "[Warn #%d]", flag);
    if (CVI(CV_LOG_WARN))
        LogLine(id, prefix, full);
    DumpFrames(id, prefix);
    NotifyAdmins(id, "Warn #%d, VL %.0f/%.0f", flag, g_fVL[id][flag], kick);
}
// Violation level storage (nvault)
// True when the authid identifies one player (not LAN, bot, pending...).
bool:IsUniqueAuth(const auth[])
{
    if (strlen(auth) < 8)
        return false;
    if (containi(auth, "LAN") != -1 || containi(auth, "PENDING") != -1 || containi(auth, "BOT") != -1
        || containi(auth, "HLTV") != -1 || containi(auth, "UNKNOWN") != -1 || containi(auth, "LOOPBACK") != -1
        || equal(auth, "STEAM_666:88:666"))
        return false;
    return true;
}
// Vault key: authid when it is unique, IP otherwise.
BuildKey(id)
{
    new auth[35];
    get_user_authid(id, auth, charsmax(auth));
    if (IsUniqueAuth(auth))
    {
        formatex(g_szKey[id], charsmax(g_szKey[]), "a_%s", auth);
        return;
    }
    new ip[16];
    get_user_ip(id, ip, charsmax(ip), 1);
    formatex(g_szKey[id], charsmax(g_szKey[]), "i_%s", ip);
}
SaveVL(id)
{
    if (g_hVault == INVALID_HANDLE || !g_szKey[id][0])
        return;
    if (CVI(CV_REMEMBER) <= 0)
        return;
    new data[256], len;
    new bool:any = false;
    for (new f = 1; f < DETECT_TOTAL; f++)
    {
        if (g_fVL[id][f] >= 1.0)
            any = true;
        len += formatex(data[len], charsmax(data) - len, "%.1f ", g_fVL[id][f]);
    }
    if (any)
        nvault_set(g_hVault, g_szKey[id], data);
    else
        nvault_remove(g_hVault, g_szKey[id]);
}
// Restores saved VL, minus the decay for the time spent offline.
LoadVL(id)
{
    if (g_hVault == INVALID_HANDLE || CVI(CV_REMEMBER) <= 0)
        return;
    if (is_user_bot(id) || is_user_hltv(id))
        return;
    BuildKey(id);
    new data[256], ts;
    if (!nvault_lookup(g_hVault, g_szKey[id], data, charsmax(data), ts))
        return;
    new age = get_systime() - ts;
    if (age < 0 || age > CVI(CV_REMEMBER) * 60)
    {
        nvault_remove(g_hVault, g_szKey[id]);
        return;
    }
    new Float:decay = CVF(CV_VL_DECAY) * float(age) / 60.0;
    new Float:cap   = CVF(CV_VL_KICK) - 1.0;
    new num[16], n, pos = 0, f = 1;
    new Float:v;
    new line[192], len;
    new bool:found = false;
    len = formatex(line, charsmax(line), "VL restored (%d sec ago):", age);
    while (data[pos] && f < DETECT_TOTAL)
    {
        while (data[pos] == ' ')
            pos++;
        n = 0;
        while (data[pos] && data[pos] != ' ' && n < charsmax(num))
            num[n++] = data[pos++];
        num[n] = 0;
        if (n == 0)
            break;
        v = floatstr(num) - decay;
        if (v > cap)
            v = cap;
        if (v >= 1.0 && g_iWeightCv[f] >= 0)
        {
            g_fVL[id][f] = v;
            if (v > g_fMaxVL[id][f])
                g_fMaxVL[id][f] = v;
            len += formatex(line[len], charsmax(line) - len, " #%d=%.0f", f, v);
            found = true;
        }
        f++;
    }
    if (found)
        LogLine(id, "[Restore]", line);
}
// Event streams
ClearStream(id, st)
{
    g_iEvHead[id][st] = 0;
    g_iEvFill[id][st] = 0;
}
PushEvent(id, st, bool:hit)
{
    new h = g_iEvHead[id][st];
    g_fEvTime[id][st][h] = get_gametime();
    g_bEvHit[id][st][h]  = hit;
    g_iEvHead[id][st]    = (h + 1) % RING;
    if (g_iEvFill[id][st] < RING)
        g_iEvFill[id][st]++;
}
// Counts events and hits that are not older than the window.
CountStream(id, st, Float:window, &total, &hits)
{
    total = 0;
    hits  = 0;
    new Float:from = get_gametime() - window;
    for (new i = 0; i < g_iEvFill[id][st]; i++)
    {
        if (g_fEvTime[id][st][i] < from)
            continue;
        total++;
        if (g_bEvHit[id][st][i])
            hits++;
    }
}
// True when the stream has enough samples and the hit rate reaches percent.
bool:StreamTriggered(id, st, Float:window, need, percent, &total, &hits, &pct)
{
    if (need > RING)
        need = RING;
    if (need < 1)
        need = 1;
    CountStream(id, st, window, total, hits);
    pct = 0;
    if (total < need)
        return false;
    pct = hits * 100 / total;
    return (pct >= percent);
}
// VL multiplier that grows with the hit rate above the threshold.
Float:ConfidenceMult(pct, percent)
{
    new Float:scale = CVF(CV_VL_SCALE);
    if (scale <= 0.0 || percent >= 100 || pct <= percent)
        return 1.0;
    new Float:m = 1.0 + scale * float(pct - percent) / float(100 - percent);
    if (m > 1.0 + scale)
        m = 1.0 + scale;
    return m;
}
// Ratio based detection: fires when the hit rate of a stream is too high.
bool:CheckStreamFlag(id, st, flag, need, percent, const what[], Float:window = 0.0, verify = -1)
{
    if (window <= 0.0)
        window = CVF(CV_WINDOW);
    new total, hits, pct;
    if (!StreamTriggered(id, st, window, need, percent, total, hits, pct))
        return false;
    new detail[160];
    formatex(detail, charsmax(detail), "%s: %d/%d (%d%%) in %.0f sec", what, hits, total, pct, window);
    ClearStream(id, st);
    new Float:mult = ConfidenceMult(pct, percent);
    if (verify >= 0)
        StartVerify(id, verify, detail, mult);
    else
        AddViolation(id, flag, detail, 0.0, mult);
    return true;
}
// Count based detection: fires after enough hits inside the window.
bool:CountFlag(id, st, flag, need, Float:window, const what[], Float:mult = 1.0)
{
    PushEvent(id, st, true);
    new total, hits;
    CountStream(id, st, window, total, hits);
    if (need < 1)
        need = 1;
    if (hits < need)
        return false;
    new detail[224];
    formatex(detail, charsmax(detail), "%s: %d in %.0f sec", what, hits, window);
    ClearStream(id, st);
    AddViolation(id, flag, detail, 0.0, mult);
    return true;
}
// Client settings verification
// Re-queries the client cvars a detection depends on. The detection is
// applied only if the answers match the values it was calculated with.
StartVerify(id, kind, const detail[], Float:mult)
{
    new flag = g_iVerifyFlag[kind];
    if (!CVI(CV_VERIFY) || !CVI(CV_QUERY))
    {
        if (kind == VERIFY_SILENT)
            Punish(id, flag, detail);
        else
            AddViolation(id, flag, detail, 0.0, mult);
        return;
    }
    if (g_iVerifyLeft[id][kind] > 0)
        return;
    copy(g_szVerifyDetail[id][kind], charsmax(g_szVerifyDetail[][]), detail);
    g_fVerifyMult[id][kind]    = mult;
    g_bVerifyChanged[id][kind] = false;
    new first = g_iVerifyFirst[kind];
    new last  = g_iVerifyLast[kind];
    new param[2];
    param[1] = kind + 1;
    g_iVerifyLeft[id][kind] = last - first + 1;
    for (new c = first; c <= last; c++)
    {
        param[0] = c;
        query_client_cvar(id, g_szClientCvars[c], "cb_ClientCvar", 2, param);
    }
    new taskid = TASK_VERIFY + kind * MAXP + id;
    remove_task(taskid);
    set_task(VERIFY_TIMEOUT, "task_VerifyTimeout", taskid);
}
FinishVerify(id, kind)
{
    remove_task(TASK_VERIFY + kind * MAXP + id);
    new flag = g_iVerifyFlag[kind];
    if (g_bVerifyChanged[id][kind])
    {
        if (CVI(CV_LOG_WARN))
            LogLine(id, "[Verify]", "client settings changed, detection cancelled");
        ClearStream(id, g_iVerifyStream[kind]);
        return;
    }
    new detail[288];
    formatex(detail, charsmax(detail), "%s, settings verified", g_szVerifyDetail[id][kind]);
    if (kind == VERIFY_SILENT)
        Punish(id, flag, detail);
    else
        AddViolation(id, flag, detail, 0.0, g_fVerifyMult[id][kind]);
}
public task_VerifyTimeout(taskid)
{
    new rest = taskid - TASK_VERIFY;
    new kind = rest / MAXP;
    new id   = rest % MAXP;
    if (kind < 0 || kind >= VERIFY_KINDS || id < 1 || id >= MAXP)
        return;
    if (g_iVerifyLeft[id][kind] <= 0)
        return;
    g_iVerifyLeft[id][kind] = 0;
    if (is_user_connected(id) && CVI(CV_LOG_WARN))
        LogLine(id, "[Verify]", "no answer to settings re-check, detection dropped");
}
// Per-second statistics
// Speed, spin and pitch statistics over the last secs seconds.
SecStats(id, secs, speedLimit, Float:spinLimit, &speedBad, &spinBad, &pitchSum, &maxMsec, &sumMsec, &sumReal, &valid)
{
    speedBad = 0;
    spinBad  = 0;
    pitchSum = 0;
    maxMsec  = 0;
    sumMsec  = 0;
    sumReal  = 0;
    valid    = 0;
    if (secs > SEC_RING)
        secs = SEC_RING;
    new s, norm;
    for (new i = 1; i <= secs; i++)
    {
        s = (g_iSecHead[id] - i + SEC_RING) % SEC_RING;
        if (!g_bSecAlive[id][s])
            continue;
        pitchSum += g_iSecPitch[id][s];
        if (g_fSecYaw[id][s] > spinLimit)
            spinBad++;
        if (g_bSecLag[id][s] || g_iSecReal[id][s] <= 0)
            continue;
        norm = g_iSecMsec[id][s] * 1000 / g_iSecReal[id][s];
        if (norm > maxMsec)
            maxMsec = norm;
        if (norm > speedLimit)
            speedBad++;
        sumMsec += g_iSecMsec[id][s];
        sumReal += g_iSecReal[id][s];
        valid++;
    }
}
// Seconds with fps above the limit over the last secs seconds.
// Usercmd msec is an integer, so at high fps it is rounded on every frame
// and frames / msec can overestimate the real fps (fps_max 101 can look like
// 111, 300 fps like 333...). The fps is therefore also measured against
// the server real time of that second and the lower of the two is used:
// a client really running above the limit is above it in both.
FpsStats(id, secs, fpsMax, &bad, &maxFps)
{
    bad    = 0;
    maxFps = 0;
    if (secs > SEC_RING)
        secs = SEC_RING;
    new s, fps, fpsReal;
    for (new i = 1; i <= secs; i++)
    {
        s = (g_iSecHead[id] - i + SEC_RING) % SEC_RING;
        if (!g_bSecAlive[id][s] || g_bSecLag[id][s] || g_iSecMsec[id][s] < 500 || g_iSecReal[id][s] < 500)
            continue;
        fps     = g_iSecFrames[id][s] * 1000 / g_iSecMsec[id][s];
        fpsReal = g_iSecFrames[id][s] * 1000 / g_iSecReal[id][s];
        if (fpsReal < fps)
            fps = fpsReal;
        if (fps > maxFps)
            maxFps = fps;
        if (fps > fpsMax)
            bad++;
    }
}
// Plugin forwards
public plugin_precache()
{
    new mins[3], maxs[3];
    for (new i = 0; i < sizeof g_szModels; i++)
        force_unmodified(force_model_samebounds, mins, maxs, g_szModels[i]);
}
public plugin_init()
{
    register_plugin(PLUGIN, VERSION, AUTHOR);
    register_cvar("simple_ac_version", VERSION, FCVAR_SERVER | FCVAR_SPONLY);
    set_cvar_string("simple_ac_version", VERSION);
    // General
    RegCvar(CV_FIRST_CHECK,           "ac_first_check",           "10.0");
    RegCvar(CV_INTERVAL,              "ac_check_interval",        "60.0");
    RegCvar(CV_IMMUNITY,              "ac_immunity",              "0");
    RegCvar(CV_NOTIFY,                "ac_notify",                "1");
    RegCvar(CV_LOG_WARN,              "ac_log_warn",              "1");
    RegCvar(CV_SNAPSHOT,              "ac_snapshot",              "1");
    RegCvar(CV_CONSOLE,               "ac_console",               "0");
    RegCvar(CV_WINDOW,                "ac_window",                "60.0");
    RegCvar(CV_SEC_WINDOW,            "ac_sec_window",            "10");
    // Violation levels
    RegCvar(CV_VL_KICK,               "ac_vl_kick",               "100");
    RegCvar(CV_VL_DECAY,              "ac_vl_decay",              "3.0");
    RegCvar(CV_VL_SCALE,              "ac_vl_scale",              "1.0");
    RegCvar(CV_REMEMBER,              "ac_remember",              "30");
    RegCvar(CV_VERIFY,                "ac_verify",                "1");
    // Lag tolerance
    RegCvar(CV_LAG_PING,              "ac_lag_ping",              "200");
    RegCvar(CV_LAG_LOSS,              "ac_lag_loss",              "5");
    // Speedhack
    RegCvar(CV_SPEED,                 "ac_speed",                 "1");
    RegCvar(CV_SPEED_LIMIT,           "ac_speed_limit",           "1200");
    RegCvar(CV_SPEED_RATIO,           "ac_speed_ratio",           "1.10");
    RegCvar(CV_SPEED_WARNS,           "ac_speed_warns",           "4");
    RegCvar(CV_SPEED_VL,              "ac_speed_vl",              "60");
    // Cvar query blocking
    RegCvar(CV_QUERY,                 "ac_query",                 "1");
    RegCvar(CV_QUERY_TIMEOUT,         "ac_query_timeout",         "15.0");
    RegCvar(CV_QUERY_FAILS,           "ac_query_fails",           "2");
    // Bhop scripts
    RegCvar(CV_JUMP_WINDOW,           "ac_jump_window",           "180.0");
    RegCvar(CV_BHOP,                  "ac_bhop",                  "1");
    RegCvar(CV_BHOP_JUMPS,            "ac_bhop_jumps",            "25");
    RegCvar(CV_BHOP_PERCENT,          "ac_bhop_percent",          "90");
    RegCvar(CV_BHOP_EXACT_JUMPS,      "ac_bhop_exact_jumps",      "12");
    RegCvar(CV_BHOP_EXACT_PERCENT,    "ac_bhop_exact_percent",    "75");
    RegCvar(CV_BHOP_TAP_JUMPS,        "ac_bhop_tap_jumps",        "15");
    RegCvar(CV_BHOP_TAP_PERCENT,      "ac_bhop_tap_percent",      "90");
    RegCvar(CV_BHOP_SPAM_JUMPS,       "ac_bhop_spam_jumps",       "10");
    RegCvar(CV_BHOP_SPAM_PERCENT,     "ac_bhop_spam_percent",     "80");
    RegCvar(CV_BHOP_VL,               "ac_bhop_vl",               "55");
    // Invalid pitch
    RegCvar(CV_PITCH,                 "ac_pitch",                 "1");
    RegCvar(CV_PITCH_LIMIT,           "ac_pitch_limit",           "89.5");
    RegCvar(CV_PITCH_WARNS,           "ac_pitch_warns",           "20");
    // Spinbot
    RegCvar(CV_SPIN,                  "ac_spin",                  "1");
    RegCvar(CV_SPIN_LIMIT,            "ac_spin_limit",            "2880");
    RegCvar(CV_SPIN_WARNS,            "ac_spin_warns",            "3");
    RegCvar(CV_SPIN_VL,               "ac_spin_vl",               "60");
    // Aim snap
    RegCvar(CV_SNAP,                  "ac_snap",                  "1");
    RegCvar(CV_SNAP_ANGLE,            "ac_snap_angle",            "10.0");
    RegCvar(CV_SNAP_RATIO,            "ac_snap_ratio",            "6.0");
    RegCvar(CV_SNAP_FOV,              "ac_snap_fov",              "3.0");
    RegCvar(CV_SNAP_COUNT,            "ac_snap_count",            "3");
    RegCvar(CV_SNAP_WINDOW,           "ac_snap_window",           "120.0");
    RegCvar(CV_SNAP_VL,               "ac_snap_vl",               "60");
    // Strafe helper
    RegCvar(CV_STRAFE,                "ac_strafe",                "1");
    RegCvar(CV_STRAFE_SAMPLES,        "ac_strafe_samples",        "40");
    RegCvar(CV_STRAFE_PERCENT,        "ac_strafe_percent",        "80");
    RegCvar(CV_STRAFE_MINTURN,        "ac_strafe_minturn",        "1.0");
    RegCvar(CV_STRAFE_VL,             "ac_strafe_vl",             "40");
    // Duck scripts (dd / gstrafe)
    RegCvar(CV_GSTRAFE,               "ac_gstrafe",               "1");
    RegCvar(CV_GSTRAFE_DUCKS,         "ac_gstrafe_ducks",         "25");
    RegCvar(CV_GSTRAFE_PERCENT,       "ac_gstrafe_percent",       "90");
    RegCvar(CV_GSTRAFE_EXACT_DUCKS,   "ac_gstrafe_exact_ducks",   "12");
    RegCvar(CV_GSTRAFE_EXACT_PERCENT, "ac_gstrafe_exact_percent", "75");
    RegCvar(CV_GSTRAFE_TAP_DUCKS,     "ac_gstrafe_tap_ducks",     "15");
    RegCvar(CV_GSTRAFE_TAP_PERCENT,   "ac_gstrafe_tap_percent",   "90");
    RegCvar(CV_GSTRAFE_SPAM_DUCKS,    "ac_gstrafe_spam_ducks",    "10");
    RegCvar(CV_GSTRAFE_SPAM_PERCENT,  "ac_gstrafe_spam_percent",  "80");
    RegCvar(CV_GSTRAFE_VL,            "ac_gstrafe_vl",            "55");
    // Move without keys
    RegCvar(CV_NOKEYS,                "ac_nokeys",                "1");
    RegCvar(CV_NOKEYS_SAMPLES,        "ac_nokeys_samples",        "50");
    RegCvar(CV_NOKEYS_PERCENT,        "ac_nokeys_percent",        "60");
    RegCvar(CV_NOKEYS_VL,             "ac_nokeys_vl",             "60");
    // Rotated move vector
    RegCvar(CV_VECTOR,                "ac_vector",                "1");
    RegCvar(CV_VECTOR_SAMPLES,        "ac_vector_samples",        "40");
    RegCvar(CV_VECTOR_PERCENT,        "ac_vector_percent",        "70");
    RegCvar(CV_VECTOR_VL,             "ac_vector_vl",             "60");
    // Fast strafe switch
    RegCvar(CV_FS,                    "ac_faststrafe",            "1");
    RegCvar(CV_FS_MS,                 "ac_faststrafe_ms",         "20");
    RegCvar(CV_FS_SAMPLES,            "ac_faststrafe_samples",    "20");
    RegCvar(CV_FS_PERCENT,            "ac_faststrafe_percent",    "60");
    RegCvar(CV_FS_VL,                 "ac_faststrafe_vl",         "60");
    // Trap cvar
    RegCvar(CV_TRAP,                  "ac_trap",                  "1");
    // Mouse step (GCD)
    RegCvar(CV_GCD,                   "ac_gcd",                   "1");
    RegCvar(CV_GCD_SAMPLES,           "ac_gcd_samples",           "40");
    RegCvar(CV_GCD_PERCENT,           "ac_gcd_percent",           "30");
    RegCvar(CV_GCD_VL,                "ac_gcd_vl",                "50");
    RegCvar(CV_GCD_CONTEXT,           "ac_gcd_context",           "1");
    RegCvar(CV_GCD_FOV,               "ac_gcd_fov",               "10.0");
    RegCvar(CV_GCD_HIT,               "ac_gcd_hit",               "1.0");
    // No-recoil
    RegCvar(CV_RECOIL,                "ac_norecoil",              "1");
    RegCvar(CV_RECOIL_SAMPLES,        "ac_norecoil_samples",      "30");
    RegCvar(CV_RECOIL_PERCENT,        "ac_norecoil_percent",      "80");
    RegCvar(CV_RECOIL_VL,             "ac_norecoil_vl",           "60");
    // Triggerbot
    RegCvar(CV_TRIGGER,               "ac_trigger",               "1");
    RegCvar(CV_TRIGGER_MS,            "ac_trigger_ms",            "50");
    RegCvar(CV_TRIGGER_IDLE,          "ac_trigger_idle",          "250");
    RegCvar(CV_TRIGGER_STILL,         "ac_trigger_still",         "1.5");
    RegCvar(CV_TRIGGER_SAMPLES,       "ac_trigger_samples",       "15");
    RegCvar(CV_TRIGGER_PERCENT,       "ac_trigger_percent",       "70");
    RegCvar(CV_TRIGGER_VL,            "ac_trigger_vl",            "60");
    // Autofire
    RegCvar(CV_AUTOFIRE,              "ac_autofire",              "1");
    RegCvar(CV_AUTOFIRE_SAMPLES,      "ac_autofire_samples",      "20");
    RegCvar(CV_AUTOFIRE_PERCENT,      "ac_autofire_percent",      "80");
    RegCvar(CV_AUTOFIRE_VL,           "ac_autofire_vl",           "60");
    // Fps limit
    RegCvar(CV_FPS,                   "ac_fps",                   "1");
    RegCvar(CV_FPS_MAX,               "ac_fps_max",               "1000");
    RegCvar(CV_FPS_WARNS,             "ac_fps_warns",             "5");
    RegCvar(CV_FPS_VL,                "ac_fps_vl",                "50");
    // Aim target search
    RegCvar(CV_REWIND,                "ac_rewind",                "1");
    RegCvar(CV_HIT_RADIUS,            "ac_hit_radius",            "12.0");
    RegCvar(CV_AIM_TARGET,            "ac_aim_target",            "1");
    // Silent aim
    RegCvar(CV_SILENT,                "ac_silent",                "1");
    RegCvar(CV_SILENT_ANGLE,          "ac_silent_angle",          "3.0");
    RegCvar(CV_SILENT_MIN,            "ac_silent_min",            "0.3");
    RegCvar(CV_SILENT_RETURN,         "ac_silent_return",         "0.35");
    RegCvar(CV_SILENT_FOV,            "ac_silent_fov",            "8.0");
    RegCvar(CV_SILENT_COUNT,          "ac_silent_count",          "4");
    RegCvar(CV_SILENT_WINDOW,         "ac_silent_window",         "120.0");
    RegCvar(CV_SILENT_VL,             "ac_silent_vl",             "60");
    RegCvar(CV_SILENT_INSTANT,        "ac_silent_instant",        "1");
    RegCvar(CV_SILENT_EXACT,          "ac_silent_exact",          "0.1");
    RegCvar(CV_SILENT_FOCUS,          "ac_silent_focus",          "0.5");
    RegCvar(CV_SILENT_MSEC,           "ac_silent_msec",           "16");
    // Smooth aim
    RegCvar(CV_SMOOTH,                "ac_smooth",                "1");
    RegCvar(CV_SMOOTH_FRAMES,         "ac_smooth_frames",         "4");
    RegCvar(CV_SMOOTH_TOL,            "ac_smooth_tol",            "0.03");
    RegCvar(CV_SMOOTH_FOV,            "ac_smooth_fov",            "3.0");
    RegCvar(CV_SMOOTH_COUNT,          "ac_smooth_count",          "5");
    RegCvar(CV_SMOOTH_WINDOW,         "ac_smooth_window",         "180.0");
    RegCvar(CV_SMOOTH_VL,             "ac_smooth_vl",             "50");
    // Headshot ratio
    RegCvar(CV_HS,                    "ac_hs",                    "1");
    RegCvar(CV_HS_KILLS,              "ac_hs_kills",              "25");
    RegCvar(CV_HS_PERCENT,            "ac_hs_percent",            "85");
    RegCvar(CV_HS_WINDOW,             "ac_hs_window",             "900.0");
    RegCvar(CV_HS_VL,                 "ac_hs_vl",                 "35");
    // Autostop
    RegCvar(CV_AUTOSTOP,              "ac_autostop",              "1");
    RegCvar(CV_AUTOSTOP_COUNT,        "ac_autostop_count",        "10");
    RegCvar(CV_AUTOSTOP_WINDOW,       "ac_autostop_window",       "60.0");
    RegCvar(CV_AUTOSTOP_VL,           "ac_autostop_vl",           "60");
    // Punishment
    RegCvar(CV_PUNISH,                "ac_punish",                "1");
    RegCvar(CV_BAN_TIME,              "ac_ban_time",              "1440");
    RegCvar(CV_ADMIN_NOTIFY,          "ac_admin_notify",          "1");
    g_pcBanCmd = register_cvar("ac_ban_cmd", "");
    for (new f = 0; f < DETECT_TOTAL; f++)
        g_iWeightCv[f] = -1;
    g_iWeightCv[DETECT_SPEED]      = CV_SPEED_VL;
    g_iWeightCv[DETECT_BHOP]       = CV_BHOP_VL;
    g_iWeightCv[DETECT_SPIN]       = CV_SPIN_VL;
    g_iWeightCv[DETECT_SNAP]       = CV_SNAP_VL;
    g_iWeightCv[DETECT_STRAFE]     = CV_STRAFE_VL;
    g_iWeightCv[DETECT_GSTRAFE]    = CV_GSTRAFE_VL;
    g_iWeightCv[DETECT_NOKEYS]     = CV_NOKEYS_VL;
    g_iWeightCv[DETECT_VECTOR]     = CV_VECTOR_VL;
    g_iWeightCv[DETECT_FASTSTRAFE] = CV_FS_VL;
    g_iWeightCv[DETECT_GCD]        = CV_GCD_VL;
    g_iWeightCv[DETECT_NORECOIL]   = CV_RECOIL_VL;
    g_iWeightCv[DETECT_TRIGGER]    = CV_TRIGGER_VL;
    g_iWeightCv[DETECT_AUTOFIRE]   = CV_AUTOFIRE_VL;
    g_iWeightCv[DETECT_FPS]        = CV_FPS_VL;
    g_iWeightCv[DETECT_SILENT]     = CV_SILENT_VL;
    g_iWeightCv[DETECT_SMOOTH]     = CV_SMOOTH_VL;
    g_iWeightCv[DETECT_HEADSHOT]   = CV_HS_VL;
    g_iWeightCv[DETECT_AUTOSTOP]   = CV_AUTOSTOP_VL;
    register_concmd("amx_acstats", "cmd_Stats", ADMIN_BAN, "[name|#userid] - without argument lists all players");
    register_concmd("amx_acdebug", "cmd_Debug", ADMIN_RCON, "<name|#userid> [seconds]");
    register_concmd("amx_acreset", "cmd_Reset", ADMIN_RCON, "<name|#userid> - clear VL and samples");
    register_forward(FM_CmdStart, "fw_CmdStart");
    register_forward(FM_StartFrame, "fw_StartFrame");
    register_event("HLTV", "ev_NewRound", "a", "1=0", "2=0");
    register_logevent("ev_RoundStart", 2, "1=Round_Start");
    g_pFreezeTime = get_cvar_pointer("mp_freezetime");
    register_event("DeathMsg", "ev_Death", "a");
    register_event("Damage", "ev_Damage", "be", "2!0");
    g_hVault      = nvault_open(VAULT_NAME);
    g_iMaxPlayers = get_maxplayers();
    get_localinfo("amxx_logs", g_szLogsDir, charsmax(g_szLogsDir));
    CacheCvars();
    g_iLastTick = tickcount();
    set_task(1.0, "task_SecondCheck", TASK_SECOND, _, _, "b");
}
public plugin_cfg()
{
    new dir[128], path[192];
    get_configsdir(dir, charsmax(dir));
    formatex(path, charsmax(path), "%s/%s", dir, CFG_FILE);
    if (file_exists(path))
    {
        server_cmd("exec ^"%s^"", path);
        server_exec();
    }
    CacheCvars();
    formatex(path, charsmax(path), "%s/%s", dir, LIST_FILE);
    LoadLists(path);
    if (g_hVault != INVALID_HANDLE)
    {
        new keep = CVI(CV_REMEMBER) * 60;
        if (keep < 86400)
            keep = 86400;
        nvault_prune(g_hVault, 0, get_systime() - keep);
    }
}
public plugin_end()
{
    if (g_hVault == INVALID_HANDLE)
        return;
    for (new id = 1; id <= g_iMaxPlayers; id++)
    {
        if (is_user_connected(id) && !g_bIgnore[id])
            SaveVL(id);
    }
    nvault_close(g_hVault);
    g_hVault = INVALID_HANDLE;
}
// Cvar lists (simple_anticheat.ini)
AddCheatCvar(const name[])
{
    if (g_iCheatCount >= MAX_LIST || !name[0])
        return;
    copy(g_szCheatCvars[g_iCheatCount], charsmax(g_szCheatCvars[]), name);
    g_iCheatCount++;
}
AddProtCvar(const name[], Float:allowed)
{
    if (g_iProtCount >= MAX_LIST || !name[0])
        return;
    copy(g_szProtCvars[g_iProtCount], charsmax(g_szProtCvars[]), name);
    g_fProtAllowed[g_iProtCount] = allowed;
    g_iProtCount++;
}
// Loads the cheat / protected cvar lists, or the defaults without the file.
LoadLists(const path[])
{
    g_iCheatCount = 0;
    g_iProtCount  = 0;
    new f = file_exists(path) ? fopen(path, "rt") : 0;
    if (!f)
    {
        for (new i = 0; i < sizeof g_szCheatCvarsDef; i++)
            AddCheatCvar(g_szCheatCvarsDef[i]);
        for (new i = 0; i < sizeof g_szProtCvarsDef; i++)
            AddProtCvar(g_szProtCvarsDef[i], g_fProtAllowedDef[i]);
        return;
    }
    new line[128], tmp[128], kind[16], name[32], value[32];
    while (!feof(f))
    {
        fgets(f, line, charsmax(line));
        if ((line[0] & 0xFF) == 0xEF && (line[1] & 0xFF) == 0xBB && (line[2] & 0xFF) == 0xBF)
        {
            copy(tmp, charsmax(tmp), line[3]);
            copy(line, charsmax(line), tmp);
        }
        trim(line);
        if (!line[0] || line[0] == ';' || line[0] == '#' || (line[0] == '/' && line[1] == '/'))
            continue;
        kind[0] = 0;
        name[0] = 0;
        value[0] = 0;
        parse(line, kind, charsmax(kind), name, charsmax(name), value, charsmax(value));
        if (equali(kind, "cheat"))
            AddCheatCvar(name);
        else if (equali(kind, "protect") && value[0])
            AddProtCvar(name, floatstr(value));
        else
            log_amx("[AC] %s: unknown line ^"%s^"", LIST_FILE, line);
    }
    fclose(f);
}
// Player state
ResetButtons(id)
{
    for (new b = 0; b < 2; b++)
    {
        g_iBtnHold[id][b]       = 0;
        g_iBtnAir[id][b]        = 0;
        g_iBtnAirLand[id][b]    = 0;
        g_iBtnAirLast[id][b]    = 0;
        g_iBtnSpamInt[id][b]    = 0;
        g_iBtnSpamHold[id][b]   = 0;
        g_iBtnSpamLand[id][b]   = 0;
        g_iBtnSpamPrev[id][b]   = 0;
        g_bBtnSampled[id][b]    = true;
        g_bBtnPend[id][b]       = false;
        g_iBtnPendGround[id][b] = 0;
        g_iBtnPendAir[id][b]    = 0;
        g_iNkSign[id][b]        = 0;
    }
    g_iGroundFrames[id] = 0;
    g_iGroundMs[id]     = 0;
    g_iAirMs[id]        = 0;
    g_iLastAirMs[id]    = 0;
}
ResetAim(id)
{
    g_fErrA[id] = AIM_NONE;
    g_fErrB[id] = AIM_NONE;
    for (new i = 0; i < 2; i++)
    {
        g_fMvA[id][i] = 0.0;
        g_fMvB[id][i] = 0.0;
    }
    g_fSmPrevMag[id] = 0.0;
    g_fSmPrevDp[id]  = 0.0;
    g_fSmPrevDy[id]  = 0.0;
    g_fSmK[id]       = 0.0;
    g_fSmT[id]       = 0.0;
    g_bSmHaveK[id]   = false;
    g_iSmRun[id]     = 0;
    g_iSmOn[id]      = 0;
    g_iSmOff[id]     = 0;
}
ResetPlayer(id)
{
    g_bKicked[id]       = false;
    g_bIgnore[id]       = false;
    g_bWasAlive[id]     = false;
    g_bLag[id]          = false;
    g_fGraceUntil[id]   = 0.0;
    g_fDebugUntil[id]   = 0.0;
    g_fLastDump[id]     = 0.0;
    g_fLastAdminMsg[id] = 0.0;
    g_szKey[id][0]      = 0;
    g_iMsec[id]         = 0;
    g_iFrames[id]       = 0;
    g_iClock[id]        = 0;
    g_iFrameNo[id]      = 0;
    g_fYawSum[id]       = 0.0;
    g_iPitchCount[id]   = 0;
    g_fLastBadPitch[id] = 0.0;
    g_iAnswered[id]     = 0;
    g_iQueryFails[id]   = 0;
    for (new c = 0; c < CL_TOTAL; c++)
        g_fCl[id][c] = g_fClientDefault[c];
    for (new k = 0; k < VERIFY_KINDS; k++)
    {
        g_iVerifyLeft[id][k]    = 0;
        g_bVerifyChanged[id][k] = false;
        g_fVerifyMult[id][k]    = 1.0;
        g_szVerifyDetail[id][k][0] = 0;
        remove_task(TASK_VERIFY + k * MAXP + id);
    }
    ResetButtons(id);
    g_iLastButtons[id]  = 0;
    g_iAngHist[id]      = 0;
    g_fDeltaA[id]       = 0.0;
    g_fDeltaB[id]       = 0.0;
    g_iLastMsec[id]     = 0;
    g_iLastMsecA[id]    = 0;
    g_iLastMouseDir[id] = 0;
    g_fSegYaw[id]       = 0.0;
    g_iLastSideDir[id]  = 0;
    g_iLastSideSign[id] = 0;
    g_iHoldMs[id]       = 0;
    g_fLastPunch[id]    = 0.0;
    g_bHasPunch[id]     = false;
    g_fHitUntil[id]     = 0.0;
    g_fHitPunch[id]     = 0.0;
    g_bOnTarget[id]     = false;
    g_bTargetIdle[id]   = false;
    g_iTargetStart[id]  = 0;
    g_iLastAttack[id]   = 0;
    g_iLastPress[id]      = 0;
    g_iLastPressFrame[id] = 0;
    g_iPrevInterval[id]   = 0;
    g_iPrevIntFrames[id]  = 0;
    g_iPrevHold[id]       = 0;
    g_iAttackHold[id]     = 0;
    g_iAttackLastHold[id] = 0;
    g_iFrHead[id] = 0;
    g_iFrFill[id] = 0;
    g_iPing[id]   = 0;
    g_fSpeedLockUntil[id] = 0.0;
    g_iRwHead[id] = 0;
    g_iRwFill[id] = 0;
    g_bAlive[id]  = false;
    g_iTeam[id]   = 0;
    ResetAim(id);
    for (new f = 0; f < DETECT_TOTAL; f++)
    {
        g_fVL[id][f]       = 0.0;
        g_fMaxVL[id][f]    = 0.0;
        g_fCooldown[id][f] = 0.0;
        g_fLogOnlyUntil[id][f] = 0.0;
    }
    for (new s = 0; s < SEC_RING; s++)
    {
        g_iSecMsec[id][s]   = 0;
        g_iSecReal[id][s]   = 0;
        g_iSecFrames[id][s] = 0;
        g_fSecYaw[id][s]    = 0.0;
        g_iSecPitch[id][s]  = 0;
        g_bSecAlive[id][s]  = false;
        g_bSecLag[id][s]    = false;
    }
    g_iSecHead[id] = 0;
    for (new st = 0; st < STREAMS; st++)
        ClearStream(id, st);
}
// Logs the highest VL the player reached during the session.
LogSession(id)
{
    new line[192], len;
    new bool:found = false;
    len = formatex(line, charsmax(line), "max VL:");
    for (new f = 1; f < DETECT_TOTAL; f++)
    {
        if (g_fMaxVL[id][f] > 0.0)
        {
            len += formatex(line[len], charsmax(line) - len, " #%d=%.0f", f, g_fMaxVL[id][f]);
            found = true;
        }
    }
    if (found)
        LogLine(id, "[Session]", line);
}
// Client forwards
public client_connect(id)
{
    ResetPlayer(id);
}
#if AMXX_VERSION_NUM < 190
public client_authorized(id)
#else
public client_authorized(id, const authid[])
#endif
{
    LoadVL(id);
}
public client_putinserver(id)
{
    if (is_user_bot(id) || is_user_hltv(id))
    {
        g_bIgnore[id] = true;
        return;
    }
    remove_task(id + TASK_CHECK);
    set_task(CVF(CV_FIRST_CHECK), "task_CvarCheck", id + TASK_CHECK);
}
#if AMXX_VERSION_NUM < 183
public client_disconnect(id)
#else
public client_disconnected(id)
#endif
{
    remove_task(id + TASK_CHECK);
    remove_task(id + TASK_QUERY);
    remove_task(id + TASK_KICK);
    if (!g_bIgnore[id])
    {
        LogSession(id);
        SaveVL(id);
    }
    ResetPlayer(id);
}
// Game events
public ev_NewRound()
{
    // Freezetime (buy time) starts with the new round.
    // If Round_Start is never logged, the freeze ends after mp_freezetime.
    g_bFreezeTime = true;
    g_fFreezeMax  = get_gametime() + (g_pFreezeTime ? get_pcvar_float(g_pFreezeTime) : 0.0) + 2.0;
    new Float:until = get_gametime() + SPAWN_GRACE;
    for (new id = 1; id <= g_iMaxPlayers; id++)
    {
        g_fGraceUntil[id] = until;
        g_iAngHist[id]    = 0;
        g_bHasPunch[id]   = false;
        g_fHitUntil[id]   = 0.0;
        g_fHitPunch[id]   = 0.0;
        g_iRwFill[id]     = 0;
        ResetAim(id);
    }
}
// Freezetime is over, players can move.
public ev_RoundStart()
{
    g_bFreezeTime = false;
    g_fFreezeEnd  = get_gametime();
}
// The player was hurt: the client is about to kick the view (punch angle).
public ev_Damage(id)
{
    if (id < 1 || id >= MAXP || CVF(CV_GCD_HIT) <= 0.0)
        return;
    HitGrace(id, get_gametime());
}
// Headshot ratio over enemy kills with firearms.
public ev_Death()
{
    if (!CVI(CV_HS))
        return;
    new killer = read_data(1);
    new victim = read_data(2);
    if (killer < 1 || killer >= MAXP || killer == victim || !is_user_connected(killer))
        return;
    if (g_bIgnore[killer] || g_bKicked[killer])
        return;
    if (victim >= 1 && victim < MAXP && get_user_team(victim) == get_user_team(killer))
        return;
    new wpn[24];
    read_data(4, wpn, charsmax(wpn));
    if (equal(wpn, "knife") || equal(wpn, "grenade") || equal(wpn, "world") || equal(wpn, "worldspawn"))
        return;
    new bool:hs = (read_data(3) != 0);
    PushEvent(killer, ST_HS, hs);
    if (hs)
        CheckStreamFlag(killer, ST_HS, DETECT_HEADSHOT, CVI(CV_HS_KILLS), CVI(CV_HS_PERCENT),
            "headshot ratio, kills", CVF(CV_HS_WINDOW));
}
// Client cvar checks
// Queries cheat, protected and settings cvars plus one random fake cvar.
public task_CvarCheck(taskid)
{
    new id = taskid - TASK_CHECK;
    if (!is_user_connected(id) || g_bKicked[id])
        return;
    g_iAnswered[id] = 0;
    new param[2];
    for (new i = 0; i < g_iCheatCount; i++)
    {
        param[0] = i;
        query_client_cvar(id, g_szCheatCvars[i], "cb_CheatCvar", 2, param);
    }
    for (new i = 0; i < g_iProtCount; i++)
    {
        param[0] = i;
        query_client_cvar(id, g_szProtCvars[i], "cb_ProtCvar", 2, param);
    }
    param[1] = 0;
    for (new i = 0; i < CL_TOTAL; i++)
    {
        param[0] = i;
        query_client_cvar(id, g_szClientCvars[i], "cb_ClientCvar", 2, param);
    }
    if (CVI(CV_TRAP))
    {
        new fake[16];
        new len = random_num(8, 12);
        fake[0] = 'a' + random_num(0, 25);
        for (new i = 1; i < len; i++)
            fake[i] = (random_num(0, 3) == 0) ? ('0' + random_num(0, 9)) : ('a' + random_num(0, 25));
        fake[len] = 0;
        param[0] = 0;
        query_client_cvar(id, fake, "cb_Trap", 2, param);
    }
    if (CVI(CV_QUERY))
    {
        remove_task(id + TASK_QUERY);
        set_task(CVF(CV_QUERY_TIMEOUT), "task_QueryTimeout", id + TASK_QUERY);
    }
    new Float:next = CVF(CV_INTERVAL) * random_float(1.0 - CHECK_JITTER, 1.0 + CHECK_JITTER);
    new Float:minNext = CVF(CV_QUERY_TIMEOUT) + 5.0;
    if (next < minNext)
        next = minNext;
    set_task(next, "task_CvarCheck", taskid);
}
// A cvar that exists only in cheats was answered.
public cb_CheatCvar(id, const cvar[], const value[], const param[])
{
    if (!is_user_connected(id))
        return;
    g_iAnswered[id]++;
    if (g_bKicked[id] || equal(value, "Bad CVAR request"))
        return;
    new detail[128];
    formatex(detail, charsmax(detail), "cheat cvar ^"%s^" = ^"%s^"", cvar, value);
    Punish(id, DETECT_CHEAT_CVAR, detail);
}
// A protected cvar must keep its allowed value.
public cb_ProtCvar(id, const cvar[], const value[], const param[])
{
    if (!is_user_connected(id))
        return;
    g_iAnswered[id]++;
    if (g_bKicked[id] || equal(value, "Bad CVAR request"))
        return;
    new idx = param[0];
    if (idx < 0 || idx >= g_iProtCount)
        return;
    if (floatabs(floatstr(value) - g_fProtAllowed[idx]) > 0.001)
    {
        new detail[128];
        formatex(detail, charsmax(detail), "%s = ^"%s^" (allowed %.1f)", cvar, value, g_fProtAllowed[idx]);
        Punish(id, DETECT_BAD_VALUE, detail);
    }
}
// Stores client settings and feeds pending verifications.
public cb_ClientCvar(id, const cvar[], const value[], const param[])
{
    if (!is_user_connected(id))
        return;
    g_iAnswered[id]++;
    new idx  = param[0];
    new kind = param[1] - 1;
    if (idx < 0 || idx >= CL_TOTAL)
        return;
    if (equal(value, "Bad CVAR request"))
    {
        if (idx == CL_SENS && CVI(CV_TRAP) && !g_bKicked[id])
            Punish(id, DETECT_TRAP, "real cvar ^"sensitivity^" reported as missing");
    }
    else
    {
        new Float:v = floatstr(value);
        if (idx > CL_SIDE || v > 0.0)
        {
            if (floatabs(v - g_fCl[id][idx]) > 0.0001)
            {
                if (idx <= CL_SIDE)
                {
                    g_bVerifyChanged[id][VERIFY_VECTOR] = true;
                    ClearStream(id, ST_VECTOR);
                }
                else if (idx <= CL_MACCEL)
                {
                    g_bVerifyChanged[id][VERIFY_GCD] = true;
                    ClearStream(id, ST_GCD);
                }
                if (idx <= CL_MACCEL)
                {
                    g_bVerifyChanged[id][VERIFY_SILENT] = true;
                    ClearStream(id, ST_SILENT_STRONG);
                }
            }
            g_fCl[id][idx] = v;
        }
    }
    if (kind >= 0 && kind < VERIFY_KINDS && g_iVerifyLeft[id][kind] > 0)
    {
        g_iVerifyLeft[id][kind]--;
        if (g_iVerifyLeft[id][kind] == 0 && !g_bKicked[id])
            FinishVerify(id, kind);
    }
}
// A cvar that cannot exist was answered: the query is being spoofed.
public cb_Trap(id, const cvar[], const value[], const param[])
{
    if (!is_user_connected(id))
        return;
    g_iAnswered[id]++;
    if (g_bKicked[id] || equal(value, "Bad CVAR request"))
        return;
    new detail[128];
    formatex(detail, charsmax(detail), "fake cvar ^"%s^" answered ^"%s^"", cvar, value);
    Punish(id, DETECT_TRAP, detail);
}
// No answers at all: the client blocks cvar queries.
public task_QueryTimeout(taskid)
{
    new id = taskid - TASK_QUERY;
    if (!is_user_connected(id) || g_bKicked[id])
        return;
    if (g_iAnswered[id] > 0)
    {
        g_iQueryFails[id] = 0;
        return;
    }
    if (g_bLag[id])
        return;
    g_iQueryFails[id]++;
    if (g_iQueryFails[id] >= CVI(CV_QUERY_FAILS))
    {
        new detail[128];
        formatex(detail, charsmax(detail), "no answer to cvar queries, %d checks in a row", g_iQueryFails[id]);
        if (!Punish(id, DETECT_NO_QUERY, detail))
            g_iQueryFails[id] = 0;
        return;
    }
    remove_task(id + TASK_CHECK);
    set_task(1.0, "task_CvarCheck", id + TASK_CHECK);
}
public inconsistent_file(id, const filename[], reason[64])
{
    new detail[128], prefix[24];
    formatex(detail, charsmax(detail), "inconsistent file: %s", filename);
    new mode = CVI(CV_PUNISH);
    if (IsImmune(id) || mode <= 0)
    {
        formatex(prefix, charsmax(prefix), (mode <= 0) ? "[LogOnly #%d]" : "[Immune #%d]", DETECT_FILE);
        LogLine(id, prefix, detail);
        return PLUGIN_HANDLED;
    }
    g_bKicked[id] = true;
    new bool:ban = (mode >= 2);
    formatex(prefix, charsmax(prefix), ban ? "[Ban #%d]" : "[Detect #%d]", DETECT_FILE);
    LogLine(id, prefix, detail);
    NotifyKick(id, DETECT_FILE, ban);
    formatex(reason, 63, "Detect #%d", DETECT_FILE);
    if (ban)
        BanPlayer(id, DETECT_FILE, reason);
    return PLUGIN_CONTINUE;
}
// Movement checks
// Tracks ground / air time and returns MOVE_* for this usercmd.
UpdateGround(id, msec)
{
    if (pev(id, pev_movetype) == MOVETYPE_FLY || pev(id, pev_waterlevel) >= 2)
    {
        g_iGroundFrames[id] = 0;
        g_iGroundMs[id]     = 0;
        g_iAirMs[id]        = 0;
        g_iLastAirMs[id]    = 0;
        return MOVE_OTHER;
    }
    if (!(pev(id, pev_flags) & FL_ONGROUND))
    {
        g_iGroundFrames[id] = 0;
        g_iGroundMs[id]     = 0;
        g_iAirMs[id]       += msec;
        return MOVE_AIR;
    }
    if (g_iGroundFrames[id] == 0)
    {
        g_iLastAirMs[id] = g_iAirMs[id];
        g_iAirMs[id]     = 0;
    }
    g_iGroundFrames[id]++;
    g_iGroundMs[id] += msec;
    return MOVE_GROUND;
}
// Jump / duck scripts: perfect, frame-exact, 1-frame tap and
// constant-interval spam presses on landing.
TrackButton(id, b, buttons, moveType, msec)
{
    new bit = g_iBtnBit[b];
    new bool:down    = (buttons & bit) != 0;
    new bool:wasDown = (g_iLastButtons[id] & bit) != 0;
    new bool:press   = down && !wasDown;
    new frame        = g_iFrameNo[id];
    new bool:on      = CVI(g_iBtnOn[b]) != 0;
    new Float:window = CVF(CV_JUMP_WINDOW);
    if (g_bBtnPend[id][b])
    {
        g_bBtnPend[id][b] = false;
        if (on)
        {
            new bool:tap = !down && g_iBtnPendAir[id][b] == 0 && g_iBtnPendGround[id][b] <= JUMP_TAP_FRAMES;
            new st = g_iBtnStTap[b];
            PushEvent(id, st, tap);
            if (tap)
            {
                new what[64];
                formatex(what, charsmax(what), "%s script, 1-frame taps on landing", g_szBtnName[b]);
                CheckStreamFlag(id, st, g_iBtnFlag[b], CVI(g_iBtnCvTapN[b]), CVI(g_iBtnCvTapP[b]), what, window);
            }
        }
    }
    new relHold = (wasDown && !down) ? g_iBtnHold[id][b] : 0;
    if (press)
        g_iBtnHold[id][b] = 1;
    else if (down)
        g_iBtnHold[id][b]++;
    else
        g_iBtnHold[id][b] = 0;
    if (moveType == MOVE_OTHER)
    {
        g_iBtnAir[id][b]      = 0;
        g_iBtnAirLast[id][b]  = 0;
        g_iBtnSpamInt[id][b]  = 0;
        g_iBtnSpamHold[id][b] = 0;
        g_bBtnSampled[id][b]  = true;
        return;
    }
    if (moveType == MOVE_AIR)
    {
        if (press)
        {
            g_iBtnAir[id][b]++;
            if (g_iBtnAirLast[id][b] > 0)
            {
                new interval = frame - g_iBtnAirLast[id][b];
                if (g_iBtnSpamInt[id][b] == 0)
                    g_iBtnSpamInt[id][b] = interval;
                else if (g_iBtnSpamInt[id][b] != interval)
                    g_iBtnSpamInt[id][b] = -1;
            }
            g_iBtnAirLast[id][b] = frame;
        }
        else if (relHold > 0 && g_iBtnAir[id][b] > 0)
        {
            if (g_iBtnSpamHold[id][b] == 0)
                g_iBtnSpamHold[id][b] = relHold;
            else if (g_iBtnSpamHold[id][b] != relHold)
                g_iBtnSpamHold[id][b] = -1;
        }
        return;
    }
    if (g_iGroundFrames[id] == 1)
    {
        g_iBtnAirLand[id][b] = g_iBtnAir[id][b];
        g_iBtnSpamLand[id][b] = (g_iBtnAir[id][b] >= SPAM_MIN_PRESSES && g_iBtnSpamInt[id][b] > 0
            && g_iBtnSpamHold[id][b] > 0) ? g_iBtnSpamInt[id][b] : 0;
        g_iBtnAir[id][b]      = 0;
        g_iBtnAirLast[id][b]  = 0;
        g_iBtnSpamInt[id][b]  = 0;
        g_iBtnSpamHold[id][b] = 0;
        g_bBtnSampled[id][b]  = (g_iLastAirMs[id] < JUMP_MIN_AIR_MS);
    }
    if (!press || g_bBtnSampled[id][b] || !on)
        return;
    if (g_iGroundMs[id] > BHOP_CHAIN_MS)
    {
        g_bBtnSampled[id][b] = true;
        return;
    }
    g_bBtnSampled[id][b] = true;
    new flag = g_iBtnFlag[b];
    new gf   = g_iGroundFrames[id];
    new air  = g_iBtnAirLand[id][b];
    new bool:perfect = (gf == 1);
    new what[64], st;
    st = g_iBtnStPerfect[b];
    PushEvent(id, st, perfect);
    if (perfect)
    {
        formatex(what, charsmax(what), "%s script, perfect presses", g_szBtnName[b]);
        CheckStreamFlag(id, st, flag, CVI(g_iBtnCvPerfN[b]), CVI(g_iBtnCvPerfP[b]), what, window);
    }
    if (msec > 0 && msec <= JUMP_EXACT_MSEC)
    {
        new bool:exact = perfect && air == 0;
        st = g_iBtnStExact[b];
        PushEvent(id, st, exact);
        if (exact)
        {
            formatex(what, charsmax(what), "%s script, frame-exact single presses", g_szBtnName[b]);
            CheckStreamFlag(id, st, flag, CVI(g_iBtnCvExactN[b]), CVI(g_iBtnCvExactP[b]), what, window);
        }
    }
    if (msec > 0 && msec <= JUMP_TAP_MSEC)
    {
        g_bBtnPend[id][b]       = true;
        g_iBtnPendGround[id][b] = gf;
        g_iBtnPendAir[id][b]    = air;
    }
    if (air >= SPAM_MIN_PRESSES)
    {
        new spam = g_iBtnSpamLand[id][b];
        new bool:regular = (spam > 0 && spam == g_iBtnSpamPrev[id][b]);
        g_iBtnSpamPrev[id][b] = spam;
        st = g_iBtnStSpam[b];
        PushEvent(id, st, regular);
        if (regular)
        {
            formatex(what, charsmax(what), "%s script, constant press interval %d frames", g_szBtnName[b], spam);
            CheckStreamFlag(id, st, flag, CVI(g_iBtnCvSpamN[b]), CVI(g_iBtnCvSpamP[b]), what, window);
        }
    }
    else
    {
        g_iBtnSpamPrev[id][b] = 0;
    }
}
// True when forward / side move match a key combination for the
// client speed cvars.
bool:IsKeyboardRatio(id, Float:fmove, Float:smove)
{
    new Float:fwd  = (fmove > 0.0) ? g_fCl[id][CL_FWD] : g_fCl[id][CL_BACK];
    new Float:side = g_fCl[id][CL_SIDE];
    if (fwd <= 0.0 || side <= 0.0)
        return true;
    new Float:af = floatabs(fmove);
    new Float:as = floatabs(smove);
    new Float:r  = (af / as) / (fwd / side);
    new Float:tol = VECTOR_TOLERANCE + 0.5 / af + 0.5 / as;
    for (new i = 0; i < sizeof g_fKeyRatios; i++)
    {
        if (floatabs(r - g_fKeyRatios[i]) <= g_fKeyRatios[i] * tol)
            return true;
    }
    return false;
}
bool:MoveRotated(id, Float:fmove, Float:smove)
{
    if (floatabs(fmove) < VECTOR_MIN_MOVE || floatabs(smove) < VECTOR_MIN_MOVE)
        return false;
    return !IsKeyboardRatio(id, fmove, smove);
}
// Movement keys are held but the move is zeroed.
// Not checked while the player cannot move (freezetime / buy time, frozen,
// locked speed) and for a short time after the unlock, because the client
// keeps sending the locked (zero) move until it gets the new maxspeed.
CheckAutostop(id, Float:fmove, Float:smove, buttons, Float:now)
{
    new Float:unlock = AUTOSTOP_UNLOCK + float(g_iPing[id]) / 1000.0;
    if (g_bFreezeTime && now > g_fFreezeMax)
    {
        g_bFreezeTime = false;
        g_fFreezeEnd  = g_fFreezeMax;
    }
    new Float:maxspeed;
    pev(id, pev_maxspeed, maxspeed);
    if (g_bFreezeTime || maxspeed <= 1.0 || (pev(id, pev_flags) & FL_FROZEN))
    {
        g_fSpeedLockUntil[id] = now + unlock;
        return;
    }
    if (now <= g_fSpeedLockUntil[id] || now <= g_fFreezeEnd + unlock)
        return;
    new fb = buttons & (IN_FORWARD | IN_BACK);
    new sb = buttons & (IN_MOVELEFT | IN_MOVERIGHT);
    new bool:fKey = (fb == IN_FORWARD || fb == IN_BACK);
    new bool:sKey = (sb == IN_MOVELEFT || sb == IN_MOVERIGHT);
    if (!fKey && !sKey)
        return;
    new bool:bad = (fKey && floatabs(fmove) < 0.5) || (sKey && floatabs(smove) < 0.5);
    if (!bad)
        return;
    CountFlag(id, ST_AUTOSTOP, DETECT_AUTOSTOP, CVI(CV_AUTOSTOP_COUNT), CVF(CV_AUTOSTOP_WINDOW),
        "autostop, movement keys held with zero move, frames");
}
// Strafe key switches on the same frame as the mouse direction.
CheckStrafe(id, Float:dyaw, Float:smove)
{
    new mouseDir = 0;
    if (dyaw > 0.05)
        mouseDir = 1;
    else if (dyaw < -0.05)
        mouseDir = -1;
    if (mouseDir == 0)
        return;
    if (mouseDir == g_iLastMouseDir[id])
    {
        g_fSegYaw[id] += floatabs(dyaw);
        return;
    }
    if (g_iLastMouseDir[id] != 0 && g_fSegYaw[id] >= CVF(CV_STRAFE_MINTURN))
    {
        new sideDir = SideDir(smove);
        PushEvent(id, ST_STRAFE, sideDir == mouseDir && g_iLastSideDir[id] != mouseDir);
        CheckStreamFlag(id, ST_STRAFE, DETECT_STRAFE, CVI(CV_STRAFE_SAMPLES), CVI(CV_STRAFE_PERCENT),
            "strafe helper, same-frame switches");
    }
    g_iLastMouseDir[id] = mouseDir;
    g_fSegYaw[id]       = floatabs(dyaw);
}
// Sign of a move value: 1, -1, or 0 below one unit.
MoveSign(Float:v)
{
    if (v >= 1.0)
        return 1;
    if (v <= -1.0)
        return -1;
    return 0;
}
// One move axis of CheckNoKeys:
//   0 = no move, 1 = backed by a key, 2 = held over, 3 = move without keys.
// "Held over" is a move with the same direction as the last key that was
// really held on this axis. The client produces it when the key state is
// frozen while the ESC menu / console is open: the move keeps its old value
// but the key bits are gone, and it can stay like that after the menu is
// closed until the key is pressed again. Cheats that move without keys
// (auto strafe, move bots) change the direction on their own, so a new
// direction without a key is still reported.
NoKeysAxis(id, axis, dir, bool:keyed, bool:still)
{
    if (dir == 0)
    {
        // A stopped move ends the held-over state, unless the view is frozen
        // (menu open): then the client may resume the old move later.
        if (!still)
            g_iNkSign[id][axis] = 0;
        return 0;
    }
    if (keyed)
    {
        g_iNkSign[id][axis] = dir;
        return 1;
    }
    if (dir == g_iNkSign[id][axis])
        return 2;
    g_iNkSign[id][axis] = 0;
    return 3;
}
// Move values without the matching buttons. Called for every usercmd so
// the held-over state is kept up to date; doCount = false only tracks.
// still = view angles did not change since the previous usercmd.
CheckNoKeys(id, Float:fmove, Float:smove, buttons, bool:still, bool:doCount)
{
    new sSign = MoveSign(smove);
    new fSign = MoveSign(fmove);
    new bool:sKey, bool:fKey;
    if (sSign < 0)
        sKey = (buttons & (IN_MOVELEFT | IN_LEFT)) != 0;
    else
        sKey = (buttons & (IN_MOVERIGHT | IN_RIGHT)) != 0;
    if (fSign > 0)
        fKey = (buttons & IN_FORWARD) != 0;
    else
        fKey = (buttons & IN_BACK) != 0;
    new sState = NoKeysAxis(id, NK_SIDE, sSign, sKey, still);
    new fState = NoKeysAxis(id, NK_FWD, fSign, fKey, still);
    if (!doCount)
        return;
    new bool:bad = (sState == 3 || fState == 3);
    // Frozen view: the mouse is not in the game (menu / console open), the
    // usercmd does not carry live input. Movement cheats turn the view.
    if (bad && still)
        return;
    // Only a held-over move (or no move at all): not a sample.
    if (!bad && sState != 1 && fState != 1)
        return;
    PushEvent(id, ST_NOKEYS, bad);
    if (bad)
        CheckStreamFlag(id, ST_NOKEYS, DETECT_NOKEYS, CVI(CV_NOKEYS_SAMPLES), CVI(CV_NOKEYS_PERCENT),
            "move without keys, frames");
}
// Move vector that a keyboard cannot produce (rotated by a cheat).
CheckVector(id, Float:fmove, Float:smove)
{
    if (floatabs(fmove) < VECTOR_MIN_MOVE || floatabs(smove) < VECTOR_MIN_MOVE)
        return;
    new bool:bad = !IsKeyboardRatio(id, fmove, smove);
    PushEvent(id, ST_VECTOR, bad);
    if (bad)
        CheckStreamFlag(id, ST_VECTOR, DETECT_VECTOR, CVI(CV_VECTOR_SAMPLES), CVI(CV_VECTOR_PERCENT),
            "non-keyboard move vector, frames", 0.0, VERIFY_VECTOR);
}
// Left / right switches faster than a human can press.
CheckFastSwitch(id, Float:smove, msec)
{
    new sign = SideDir(smove);
    if (sign == 0 || sign == g_iLastSideSign[id])
    {
        g_iHoldMs[id] += msec;
        return;
    }
    if (g_iLastSideSign[id] == 0)
    {
        g_iLastSideSign[id] = sign;
        g_iHoldMs[id]       = msec;
        return;
    }
    PushEvent(id, ST_FASTSW, g_iHoldMs[id] <= CVI(CV_FS_MS));
    g_iLastSideSign[id] = sign;
    g_iHoldMs[id]       = msec;
    CheckStreamFlag(id, ST_FASTSW, DETECT_FASTSTRAFE, CVI(CV_FS_SAMPLES), CVI(CV_FS_PERCENT),
        "fast strafe switch");
}
// Targets and lag compensation
// Line of sight through glass and other see-through entities.
bool:TraceClear(skip, const Float:from[3], const Float:to[3])
{
    new Float:start[3], Float:frac, Float:endpos[3];
    new hit, ignore = skip;
    start[0] = from[0];
    start[1] = from[1];
    start[2] = from[2];
    for (new pass = 0; pass <= TRACE_PASSES; pass++)
    {
        engfunc(EngFunc_TraceLine, start, to, IGNORE_MONSTERS | IGNORE_GLASS, ignore, 0);
        get_tr2(0, TR_flFraction, frac);
        if (frac >= 1.0)
            return true;
        hit = get_tr2(0, TR_pHit);
        if (hit <= 32 || !pev_valid(hit) || pev(hit, pev_rendermode) == kRenderNormal)
            return false;
        get_tr2(0, TR_vecEndPos, endpos);
        start[0] = endpos[0];
        start[1] = endpos[1];
        start[2] = endpos[2];
        ignore   = hit;
    }
    return false;
}
// Refreshes the alive / team cache and, when asked, the position history.
SnapshotPlayers(Float:now, bool:record)
{
    new h, Float:org[3];
    for (new e = 1; e <= g_iMaxPlayers; e++)
    {
        g_bAlive[e] = (is_user_alive(e) != 0);
        if (!g_bAlive[e])
        {
            g_iTeam[e]   = 0;
            g_iRwFill[e] = 0;
            continue;
        }
        g_iTeam[e] = get_user_team(e);
        if (!record)
            continue;
        h = g_iRwHead[e];
        pev(e, pev_origin, org);
        g_fRwOrg[e][h][0] = org[0];
        g_fRwOrg[e][h][1] = org[1];
        g_fRwOrg[e][h][2] = org[2];
        g_bRwDuck[e][h] = (pev(e, pev_flags) & FL_DUCKING) != 0;
        g_fRwTime[e][h] = now;
        g_iRwHead[e] = (h + 1) % RW_SIZE;
        if (g_iRwFill[e] < RW_SIZE)
            g_iRwFill[e]++;
    }
}
public fw_StartFrame()
{
    new Float:now = get_gametime();
    if (now >= g_fRwLast && now - g_fRwLast < RW_STEP)
        return FMRES_IGNORED;
    g_fRwLast = now;
    SnapshotPlayers(now, CVI(CV_REWIND) != 0);
    return FMRES_IGNORED;
}
// Position of a player at time t, interpolated from the history.
GetRewound(e, Float:t, Float:out[3], &bool:duck)
{
    new fill = g_iRwFill[e];
    if (fill == 0)
    {
        pev(e, pev_origin, out);
        duck = (pev(e, pev_flags) & FL_DUCKING) != 0;
        return;
    }
    new newer = (g_iRwHead[e] - 1 + RW_SIZE) % RW_SIZE;
    new older;
    if (g_fRwTime[e][newer] <= t)
    {
        out[0] = g_fRwOrg[e][newer][0];
        out[1] = g_fRwOrg[e][newer][1];
        out[2] = g_fRwOrg[e][newer][2];
        duck = g_bRwDuck[e][newer];
        return;
    }
    for (new i = 1; i < fill; i++)
    {
        older = (g_iRwHead[e] - 1 - i + RW_SIZE * 2) % RW_SIZE;
        if (g_fRwTime[e][older] <= t)
        {
            new Float:span = g_fRwTime[e][newer] - g_fRwTime[e][older];
            new Float:f = (span > 0.0) ? (t - g_fRwTime[e][older]) / span : 0.0;
            new Float:jump = get_distance_f(g_fRwOrg[e][older], g_fRwOrg[e][newer]);
            if (jump > 64.0)
                f = 1.0;
            for (new k = 0; k < 3; k++)
                out[k] = g_fRwOrg[e][older][k] + (g_fRwOrg[e][newer][k] - g_fRwOrg[e][older][k]) * f;
            duck = g_bRwDuck[e][(f < 0.5) ? older : newer];
            return;
        }
        newer = older;
    }
    out[0] = g_fRwOrg[e][newer][0];
    out[1] = g_fRwOrg[e][newer][1];
    out[2] = g_fRwOrg[e][newer][2];
    duck = g_bRwDuck[e][newer];
}
Float:LerpSec(id)
{
    new Float:lerp = g_fCl[id][CL_INTERP];
    if (lerp < 0.01)
        lerp = 0.01;
    if (lerp > 0.1)
        lerp = 0.1;
    return lerp;
}
// Angle between the view and the nearest visible enemy (AIM_NONE if none).
// onTarget is set when the view line passes within ac_hit_radius.
Float:AimError(id, const Float:angles[3], &target, &bool:onTarget)
{
    target   = 0;
    onTarget = false;
    new Float:eye[3], Float:dir[3];
    GetEye(id, eye);
    new Float:sp = floatsin(angles[0], degrees);
    new Float:cp = floatcos(angles[0], degrees);
    new Float:sy = floatsin(angles[1], degrees);
    new Float:cy = floatcos(angles[1], degrees);
    dir[0] = cp * cy;
    dir[1] = cp * sy;
    dir[2] = -sp;
    new bool:rewind = CVI(CV_REWIND) != 0;
    new Float:when = get_gametime() - float(g_iPing[id]) / 1000.0 - LerpSec(id);
    new team = get_user_team(id);
    new Float:org[3], Float:base[3], Float:q[3], Float:bestQ[3], Float:p[3];
    new bool:duck;
    new Float:h, Float:w0[3], Float:b, Float:d, Float:ez, Float:den, Float:t, Float:s, Float:dist, Float:err;
    new Float:best = AIM_NONE, Float:bestDist = 0.0;
    for (new e = 1; e <= g_iMaxPlayers; e++)
    {
        if (e == id || !g_bAlive[e] || g_iTeam[e] == team)
            continue;
        if (rewind)
            GetRewound(e, when, org, duck);
        else
        {
            pev(e, pev_origin, org);
            duck = (pev(e, pev_flags) & FL_DUCKING) != 0;
        }
        base[0] = org[0];
        base[1] = org[1];
        base[2] = org[2] + (duck ? -12.0 : -28.0);
        h = duck ? 25.0 : 55.0;
        for (new i = 0; i < 3; i++)
            w0[i] = eye[i] - base[i];
        b   = dir[2];
        d   = dir[0] * w0[0] + dir[1] * w0[1] + dir[2] * w0[2];
        ez  = w0[2];
        den = 1.0 - b * b;
        t   = (den < 0.0001) ? ez : (ez - b * d) / den;
        if (t < 0.0)
            t = 0.0;
        if (t > h)
            t = h;
        s = t * b - d;
        if (s < 16.0)
            continue;
        q[0] = base[0];
        q[1] = base[1];
        q[2] = base[2] + t;
        for (new i = 0; i < 3; i++)
            p[i] = eye[i] + dir[i] * s - q[i];
        dist = floatsqroot(p[0] * p[0] + p[1] * p[1] + p[2] * p[2]);
        err  = floatatan2(dist, s, degrees);
        if (err < best)
        {
            best     = err;
            bestDist = dist;
            target   = e;
            bestQ[0] = q[0];
            bestQ[1] = q[1];
            bestQ[2] = q[2];
        }
    }
    if (!target || best > AIM_MAX_ERR || !TraceClear(id, eye, bestQ))
    {
        target = 0;
        return AIM_NONE;
    }
    onTarget = (bestDist <= CVF(CV_HIT_RADIUS));
    return best;
}
// Aim checks
// Smallest yaw step the mouse can produce, 0.0 when it is unknown.
Float:GcdStep(id, buttons)
{
    if (buttons & (IN_LEFT | IN_RIGHT))
        return 0.0;
    if (g_fCl[id][CL_MFILTER] != 0.0 || g_fCl[id][CL_MACCEL] != 0.0)
        return 0.0;
    new Float:fov;
    pev(id, pev_fov, fov);
    if (fov > 0.0 && fov < 89.0)
        return 0.0;
    new Float:step = g_fCl[id][CL_SENS] * floatabs(g_fCl[id][CL_MYAW]);
    if (step < GCD_MIN_STEP)
        return 0.0;
    return step;
}
// Is the turn a multiple of the mouse step? 1 = no, 0 = yes, -1 = skip.
OffStep(Float:step, Float:v)
{
    new Float:ad = floatabs(v);
    if (step <= 0.0 || ad < step || ad > 30.0)
        return -1;
    new Float:rem = floatabs(ad - step * float(floatround(ad / step)));
    return (rem > GCD_TOLERANCE) ? 1 : 0;
}
// Pauses GCD until the view kick is over (ping covers the client delay).
HitGrace(id, Float:now)
{
    new Float:until = now + CVF(CV_GCD_HIT) + float(g_iPing[id]) / 1000.0;
    if (until > g_fHitUntil[id])
        g_fHitUntil[id] = until;
}
// Is the view moved by a kick that is not the mouse (hit, fall)?
// The punch angle grows without own shooting -> a kick starts; while it is
// still decaying the pause is held open.
bool:HitView(id, buttons, Float:now)
{
    if (CVF(CV_GCD_HIT) <= 0.0)
        return false;
    new Float:punch[3];
    pev(id, pev_punchangle, punch);
    new Float:len = floatabs(punch[0]) + floatabs(punch[1]) + floatabs(punch[2]);
    new bool:shooting = ((buttons | g_iLastButtons[id]) & IN_ATTACK) != 0;
    if (!shooting && (len > g_fHitPunch[id] + HIT_PUNCH_MIN
        || (len > HIT_PUNCH_IDLE && now <= g_fHitUntil[id])))
        HitGrace(id, now);
    g_fHitPunch[id] = len;
    return now <= g_fHitUntil[id];
}
CheckGcd(id, Float:dyaw, buttons, Float:err)
{
    new bool:context = CVI(CV_GCD_CONTEXT) != 0;
    if (context && err > CVF(CV_GCD_FOV))
        return;
    new bad = OffStep(GcdStep(id, buttons), dyaw);
    if (bad < 0)
        return;
    PushEvent(id, ST_GCD, bad == 1);
    if (bad == 1)
        CheckStreamFlag(id, ST_GCD, DETECT_GCD, CVI(CV_GCD_SAMPLES), CVI(CV_GCD_PERCENT),
            context ? "aim gcd near enemy, off-step turns" : "aim gcd, off-step turns", 0.0, VERIFY_GCD);
}
// View pitch that exactly compensates the punch angle.
CheckRecoil(id, Float:pitch, buttons, weapon)
{
    new Float:punch[3];
    pev(id, pev_punchangle, punch);
    if ((buttons & IN_ATTACK) && WeaponIn(weapon, BITS_AUTO) && g_bHasPunch[id] && g_iAngHist[id] > 0)
    {
        new Float:dPunch = punch[0] - g_fLastPunch[id];
        if (floatabs(dPunch) >= RECOIL_MIN_PUNCH)
        {
            new Float:dPitch = NormalizeAngle(pitch - g_fAngB[id][0]);
            new bool:hit = (floatabs(dPitch + dPunch) < RECOIL_TOLERANCE
                || floatabs(dPitch + 2.0 * dPunch) < RECOIL_TOLERANCE);
            PushEvent(id, ST_RECOIL, hit);
            if (hit)
                CheckStreamFlag(id, ST_RECOIL, DETECT_NORECOIL, CVI(CV_RECOIL_SAMPLES), CVI(CV_RECOIL_PERCENT),
                    "no-recoil, compensated frames");
        }
    }
    g_fLastPunch[id] = punch[0];
    g_bHasPunch[id]  = true;
}
// Strict conditions for a silent aim sample that may be punished at once.
bool:SilentClean(id, msecC, Float:dAB, Float:dBC, Float:mn, Float:dAC, Float:errA, Float:errB, Float:errC)
{
    if (g_bLag[id] || g_bHitch)
        return false;
    new maxMsec = CVI(CV_SILENT_MSEC);
    if (g_iLastMsecA[id] <= 0 || g_iLastMsec[id] <= 0 || msecC <= 0)
        return false;
    if (g_iLastMsecA[id] > maxMsec || g_iLastMsec[id] > maxMsec || msecC > maxMsec)
        return false;
    if (dAC > CVF(CV_SILENT_EXACT) * mn)
        return false;
    if (errB >= AIM_NONE || errB > CVF(CV_SILENT_FOV))
        return false;
    new Float:focus = CVF(CV_SILENT_FOCUS);
    if (errB > focus * errA || errB > focus * errC)
        return false;
    if (errA < errB + 0.5 * dAB || errC < errB + 0.5 * dBC)
        return false;
    return true;
}
SilentInstant(id, const detail[])
{
    if (g_bKicked[id])
        return;
    PushEvent(id, ST_SILENT_STRONG, true);
    if (g_iVerifyLeft[id][VERIFY_SILENT] > 0)
        return;
    new total, hits;
    new Float:window = CVF(CV_SILENT_WINDOW);
    CountStream(id, ST_SILENT_STRONG, window, total, hits);
    new need = CVI(CV_SILENT_COUNT);
    if (need < 1)
        need = 1;
    if (hits < need)
        return;
    new full[256];
    formatex(full, charsmax(full), "%s: instant, %d strong in %.0f sec", detail, hits, window);
    ClearStream(id, ST_SILENT_STRONG);
    StartVerify(id, VERIFY_SILENT, full, 1.0);
}
// One-frame turns around a shot: silent aim (turn and return) and aim snap.
CheckSnap(id, const Float:angles[3], Float:dBC, buttons, Float:errC, Float:fmove, Float:smove, msec)
{
    if (g_iLastMsec[id] <= 0 || g_iLastMsec[id] > 25 || g_bLag[id])
        return;
    new bool:attackB = (g_iLastButtons[id] & IN_ATTACK) != 0;
    new bool:attackC = (buttons & IN_ATTACK) != 0;
    if (!attackB && !attackC)
        return;
    new bool:needTarget = CVI(CV_AIM_TARGET) != 0;
    new Float:dA   = g_fDeltaA[id];
    new Float:dAB  = g_fDeltaB[id];
    new Float:dAC  = AngleDist(angles[0], angles[1], g_fAngA[id][0], g_fAngA[id][1]);
    new Float:errA = g_fErrA[id];
    new Float:errB = g_fErrB[id];
    new Float:mn   = (dAB < dBC) ? dAB : dBC;
    new detail[192];
    if (CVI(CV_SILENT) && attackB && mn >= CVF(CV_SILENT_MIN) && dAC <= CVF(CV_SILENT_RETURN) * mn)
    {
        new bool:movefix = MoveRotated(id, g_fMvB[id][0], g_fMvB[id][1])
            && !MoveRotated(id, g_fMvA[id][0], g_fMvA[id][1]) && !MoveRotated(id, fmove, smove);
        new bool:big = (mn >= CVF(CV_SILENT_ANGLE));
        new Float:step = GcdStep(id, buttons | g_iLastButtons[id]);
        new o1 = OffStep(step, NormalizeAngle(g_fAngB[id][1] - g_fAngA[id][1]));
        new o2 = OffStep(step, NormalizeAngle(angles[1] - g_fAngB[id][1]));
        new bool:offstep = (o1 == 1 && o2 == 1);
        new bool:strong = big || offstep || movefix;
        new bool:onEnemy = (errB < errA && errB <= CVF(CV_SILENT_FOV));
        if (strong && (!needTarget || onEnemy))
        {
            new bool:instant = CVI(CV_SILENT_INSTANT) != 0 && onEnemy && ((big && offstep) || movefix)
                && SilentClean(id, msec, dAB, dBC, mn, dAC, errA, errB, errC);
            formatex(detail, charsmax(detail), "silent aim, one-frame shot turns (last %.2f deg, back %.2f, enemy %.1f deg%s%s%s)",
                mn, dAC, errB, movefix ? ", movefix" : "", offstep ? ", off-step" : "", instant ? ", strong" : "");
            CountFlag(id, ST_SILENT, DETECT_SILENT, CVI(CV_SILENT_COUNT), CVF(CV_SILENT_WINDOW), detail,
                movefix ? 1.5 : 1.0);
            if (instant)
                SilentInstant(id, detail);
            return;
        }
    }
    if (!CVI(CV_SNAP))
        return;
    new Float:around = (dA > dBC) ? dA : dBC;
    if (dAB < CVF(CV_SNAP_ANGLE) || dAB < CVF(CV_SNAP_RATIO) * around)
        return;
    if (needTarget)
    {
        new Float:land = (errB < errC) ? errB : errC;
        if (land > CVF(CV_SNAP_FOV) || errA < land + 0.5 * dAB)
            return;
    }
    formatex(detail, charsmax(detail), "aim snap, single-frame lock (last %.1f deg, enemy %.1f -> %.1f deg)",
        dAB, errA, errB);
    CountFlag(id, ST_SNAP, DETECT_SNAP, CVI(CV_SNAP_COUNT), CVF(CV_SNAP_WINDOW), detail);
}
// Ends a smooth aim run and scores it.
SmoothEnd(id, Float:err)
{
    new run = g_iSmRun[id];
    g_iSmRun[id] = 0;
    new need = CVI(CV_SMOOTH_FRAMES);
    if (need < 2)
        need = 2;
    new known = g_iSmOn[id] + g_iSmOff[id];
    if (known == 0)
        need += 2;
    if (run < need || !CVI(CV_SMOOTH))
        return;
    if (g_iSmOn[id] >= g_iSmOff[id] && known > 0)
        return;
    if (CVI(CV_AIM_TARGET) && (err > CVF(CV_SMOOTH_FOV) || g_fSmStartErr[id] <= err))
        return;
    new detail[160];
    formatex(detail, charsmax(detail), "smooth aim, %d frames x%.3f (off-step %d/%d, enemy %.1f -> %.1f deg)",
        run + 2, (g_fSmKMin[id] + g_fSmKMax[id]) * 0.5, g_iSmOff[id], known, g_fSmStartErr[id], err);
    CountFlag(id, ST_SMOOTH, DETECT_SMOOTH, CVI(CV_SMOOTH_COUNT), CVF(CV_SMOOTH_WINDOW), detail);
}
// Aim deltas shrinking by a constant factor every frame.
CheckSmooth(id, Float:dp, Float:dy, buttons, Float:err)
{
    new Float:mag = floatsqroot(dp * dp + dy * dy);
    new Float:endErr = (err < g_fErrB[id]) ? err : g_fErrB[id];
    if (mag < SMOOTH_MIN_MAG || mag > 40.0 || (buttons & (IN_LEFT | IN_RIGHT)))
    {
        SmoothEnd(id, endErr);
        g_fSmPrevMag[id] = 0.0;
        g_bSmHaveK[id]   = false;
        return;
    }
    if (g_fSmPrevMag[id] <= 0.0)
    {
        g_fSmPrevMag[id] = mag;
        g_fSmPrevDp[id]  = dp;
        g_fSmPrevDy[id]  = dy;
        g_bSmHaveK[id]   = false;
        return;
    }
    new Float:prev = g_fSmPrevMag[id];
    new Float:k = mag / prev;
    new Float:t = floatatan2(g_fSmPrevDp[id] * dy - g_fSmPrevDy[id] * dp,
        g_fSmPrevDp[id] * dp + g_fSmPrevDy[id] * dy, degrees);
    if (g_bSmHaveK[id])
    {
        new Float:tolK = CVF(CV_SMOOTH_TOL) + SMOOTH_QUANT / mag + SMOOTH_QUANT / prev;
        new Float:tolT = 2.0 + 57.3 * SMOOTH_QUANT / mag;
        new bool:ok = (k >= SMOOTH_K_MIN && k <= SMOOTH_K_MAX && floatabs(t) <= 45.0
            && floatabs(k - g_fSmK[id]) <= tolK && floatabs(t - g_fSmT[id]) <= tolT);
        if (ok && g_iSmRun[id] > 0)
        {
            new Float:lo = (k < g_fSmKMin[id]) ? k : g_fSmKMin[id];
            new Float:hi = (k > g_fSmKMax[id]) ? k : g_fSmKMax[id];
            if (hi - lo > 2.0 * tolK)
                ok = false;
        }
        if (ok)
        {
            new Float:step = GcdStep(id, buttons);
            if (g_iSmRun[id] == 0)
            {
                g_fSmKMin[id]     = g_fSmK[id];
                g_fSmKMax[id]     = g_fSmK[id];
                g_fSmStartErr[id] = g_fErrA[id];
                g_iSmOn[id]       = 0;
                g_iSmOff[id]      = 0;
                new o0 = OffStep(step, g_fSmPrevDy[id]);
                if (o0 == 1)
                    g_iSmOff[id]++;
                else if (o0 == 0)
                    g_iSmOn[id]++;
            }
            if (k < g_fSmKMin[id])
                g_fSmKMin[id] = k;
            if (k > g_fSmKMax[id])
                g_fSmKMax[id] = k;
            new o = OffStep(step, dy);
            if (o == 1)
                g_iSmOff[id]++;
            else if (o == 0)
                g_iSmOn[id]++;
            g_iSmRun[id]++;
        }
        else
        {
            SmoothEnd(id, endErr);
        }
    }
    g_fSmK[id]       = k;
    g_fSmT[id]       = t;
    g_bSmHaveK[id]   = true;
    g_fSmPrevMag[id] = mag;
    g_fSmPrevDp[id]  = dp;
    g_fSmPrevDy[id]  = dy;
}
// Shots fired the moment the crosshair reaches an enemy.
CheckTrigger(id, bool:on, buttons, Float:speed)
{
    if (on && !g_bOnTarget[id])
    {
        g_iTargetStart[id] = g_iClock[id];
        g_bTargetIdle[id]  = (g_iClock[id] - g_iLastAttack[id] >= CVI(CV_TRIGGER_IDLE));
    }
    g_bOnTarget[id] = on;
    if (!on || !g_bTargetIdle[id] || !(buttons & IN_ATTACK) || (g_iLastButtons[id] & IN_ATTACK))
        return;
    g_bTargetIdle[id] = false;
    if (speed > CVF(CV_TRIGGER_STILL))
        return;
    new allow = CVI(CV_TRIGGER_MS);
    if (!CVI(CV_REWIND))
        allow += g_iPing[id] + floatround(LerpSec(id) * 1000.0);
    new reaction = g_iClock[id] - g_iTargetStart[id];
    new bool:hit = (reaction <= allow);
    PushEvent(id, ST_TRIGGER, hit);
    if (hit)
        CheckStreamFlag(id, ST_TRIGGER, DETECT_TRIGGER, CVI(CV_TRIGGER_SAMPLES), CVI(CV_TRIGGER_PERCENT),
            "triggerbot, instant shots");
}
// Pistol clicks with a constant interval / hold pattern.
CheckAutofire(id, buttons, weapon, msec)
{
    new bool:down = (buttons & IN_ATTACK) != 0;
    new bool:was  = (g_iLastButtons[id] & IN_ATTACK) != 0;
    if (down && was)
    {
        g_iAttackHold[id]++;
        return;
    }
    if (!down)
    {
        if (was)
            g_iAttackLastHold[id] = g_iAttackHold[id];
        return;
    }
    g_iAttackHold[id] = 1;
    if (!WeaponIn(weapon, BITS_PISTOL))
    {
        g_iLastPress[id]      = 0;
        g_iLastPressFrame[id] = 0;
        g_iPrevInterval[id]   = 0;
        g_iPrevIntFrames[id]  = 0;
        g_iPrevHold[id]       = 0;
        return;
    }
    new interval  = g_iClock[id] - g_iLastPress[id];
    new intFrames = g_iFrameNo[id] - g_iLastPressFrame[id];
    new hold      = g_iAttackLastHold[id];
    new bool:first = (g_iLastPress[id] == 0);
    g_iLastPress[id]      = g_iClock[id];
    g_iLastPressFrame[id] = g_iFrameNo[id];
    if (first || interval > AUTOFIRE_MAX_GAP)
    {
        g_iPrevInterval[id]  = 0;
        g_iPrevIntFrames[id] = 0;
        g_iPrevHold[id]      = 0;
        return;
    }
    new bool:have = false;
    new bool:hit  = false;
    if (msec <= AUTOFIRE_MAX_MSEC)
    {
        if (g_iPrevInterval[id] > 0)
        {
            have = true;
            hit  = (IntAbs(interval - g_iPrevInterval[id]) <= 1);
        }
    }
    else if (g_iPrevIntFrames[id] > 0 && g_iPrevHold[id] > 0)
    {
        have = true;
        hit  = (hold <= AUTOFIRE_MAX_HOLD && hold == g_iPrevHold[id] && intFrames == g_iPrevIntFrames[id]);
    }
    g_iPrevInterval[id]  = interval;
    g_iPrevIntFrames[id] = intFrames;
    g_iPrevHold[id]      = hold;
    if (!have)
        return;
    PushEvent(id, ST_AUTOFIRE, hit);
    if (hit)
        CheckStreamFlag(id, ST_AUTOFIRE, DETECT_AUTOFIRE, CVI(CV_AUTOFIRE_SAMPLES), CVI(CV_AUTOFIRE_PERCENT),
            "autofire, equal click pattern");
}
// Usercmd processing
public fw_CmdStart(id, uc_handle, seed)
{
    if (id < 1 || id >= MAXP || g_bIgnore[id] || g_bKicked[id])
        return FMRES_IGNORED;
    if (!is_user_alive(id))
    {
        g_bWasAlive[id] = false;
        return FMRES_IGNORED;
    }
    new msec      = get_uc(uc_handle, UC_Msec);
    new buttons   = get_uc(uc_handle, UC_Buttons);
    new weapon    = get_user_weapon(id);
    new Float:now = get_gametime();
    if (!g_bWasAlive[id])
    {
        g_bWasAlive[id]       = true;
        g_iAngHist[id]        = 0;
        g_iLastMouseDir[id]   = 0;
        g_iLastSideSign[id]   = 0;
        g_bHasPunch[id]       = false;
        g_fHitUntil[id]       = 0.0;
        g_fHitPunch[id]       = 0.0;
        g_bOnTarget[id]       = false;
        g_bTargetIdle[id]     = false;
        g_iLastPress[id]      = 0;
        g_iLastPressFrame[id] = 0;
        g_iPrevInterval[id]   = 0;
        g_iPrevIntFrames[id]  = 0;
        g_iPrevHold[id]       = 0;
        g_iAttackHold[id]     = 0;
        g_iAttackLastHold[id] = 0;
        g_fGraceUntil[id]     = now + SPAWN_GRACE;
        ResetButtons(id);
        ResetAim(id);
        g_iLastButtons[id] = buttons;
    }
    new Float:angles[3];
    get_uc(uc_handle, UC_ViewAngles, angles);
    new Float:fmove, Float:smove;
    get_uc(uc_handle, UC_ForwardMove, fmove);
    get_uc(uc_handle, UC_SideMove, smove);
    g_iMsec[id]  += msec;
    g_iClock[id] += msec;
    g_iFrames[id]++;
    g_iFrameNo[id]++;
    new bool:grace = (now <= g_fGraceUntil[id]);
    new bool:hitView = HitView(id, buttons, now);
    new moveType = UpdateGround(id, msec);
    TrackButton(id, BTN_JUMP, buttons, moveType, msec);
    TrackButton(id, BTN_DUCK, buttons, moveType, msec);
    new bool:still = (g_iAngHist[id] > 0 && angles[0] == g_fAngB[id][0] && angles[1] == g_fAngB[id][1]);
    CheckNoKeys(id, fmove, smove, buttons, still, moveType != MOVE_OTHER && CVI(CV_NOKEYS) != 0 && !grace);
    if (moveType == MOVE_AIR)
    {
        if (CVI(CV_VECTOR) && !grace)
            CheckVector(id, fmove, smove);
        if (CVI(CV_FS))
            CheckFastSwitch(id, smove, msec);
    }
    else
    {
        g_iLastSideSign[id] = 0;
    }
    if (CVI(CV_PITCH) && floatabs(NormalizeAngle(angles[0])) > CVF(CV_PITCH_LIMIT))
    {
        g_iPitchCount[id]++;
        g_fLastBadPitch[id] = angles[0];
    }
    if (CVI(CV_RECOIL) && !grace)
        CheckRecoil(id, angles[0], buttons, weapon);
    if (CVI(CV_AUTOSTOP) && !grace && moveType != MOVE_OTHER)
        CheckAutostop(id, fmove, smove, buttons, now);
    new Float:dBC  = 0.0;
    new Float:dyaw = 0.0;
    new Float:dpitch = 0.0;
    if (g_iAngHist[id] > 0)
    {
        dyaw   = NormalizeAngle(angles[1] - g_fAngB[id][1]);
        dpitch = NormalizeAngle(angles[0] - g_fAngB[id][0]);
        dBC    = AngleDist(angles[0], angles[1], g_fAngB[id][0], g_fAngB[id][1]);
    }
    new Float:err = AIM_NONE;
    new target = 0;
    new bool:onTarget = false;
    new bool:gun = (weapon > 0 && !WeaponIn(weapon, BITS_NOGUN));
    if (gun && !grace && !g_bLag[id] && (CVI(CV_TRIGGER) || CVI(CV_SNAP) || CVI(CV_SILENT)
        || CVI(CV_SMOOTH) || (CVI(CV_GCD) && CVI(CV_GCD_CONTEXT))))
        err = AimError(id, angles, target, onTarget);
    if (CVI(CV_TRIGGER) && !grace && !g_bLag[id])
        CheckTrigger(id, onTarget, buttons, (dBC > g_fDeltaB[id]) ? dBC : g_fDeltaB[id]);
    if (buttons & IN_ATTACK)
        g_iLastAttack[id] = g_iClock[id];
    if (CVI(CV_AUTOFIRE))
        CheckAutofire(id, buttons, weapon, msec);
    if (g_iAngHist[id] > 0)
    {
        g_fYawSum[id] += floatabs(dyaw);
        if (moveType == MOVE_AIR && CVI(CV_STRAFE))
            CheckStrafe(id, dyaw, smove);
        if (!grace && !hitView && CVI(CV_GCD))
            CheckGcd(id, dyaw, buttons, err);
        if (!grace && gun && CVI(CV_SMOOTH))
            CheckSmooth(id, dpitch, dyaw, buttons, err);
        if (g_iAngHist[id] >= 3 && (CVI(CV_SNAP) || CVI(CV_SILENT)) && !grace && gun)
            CheckSnap(id, angles, dBC, buttons, err, fmove, smove, msec);
    }
    if (moveType != MOVE_AIR)
    {
        g_iLastMouseDir[id] = 0;
        g_fSegYaw[id]       = 0.0;
    }
    RecordFrame(id, moveType, msec, angles[0], angles[1], fmove, smove, buttons);
    if (g_fDebugUntil[id] > now)
    {
        new name[32], line[160];
        get_user_name(id, name, charsmax(name));
        FormatFrame(line, charsmax(line), moveType, msec, angles[0], angles[1], fmove, smove, buttons);
        LogFile(DEBUG_FILE, "%s | %s dyaw=%.3f dpitch=%.3f aimerr=%.2f%s%s tgt=%d gf=%d", name, line, dyaw, dpitch,
            (err >= AIM_NONE) ? -1.0 : err, onTarget ? " ON" : "", hitView ? " HIT" : "", target, g_iGroundFrames[id]);
    }
    g_iLastSideDir[id] = SideDir(smove);
    g_fAngA[id][0] = g_fAngB[id][0];
    g_fAngA[id][1] = g_fAngB[id][1];
    g_fAngB[id][0] = angles[0];
    g_fAngB[id][1] = angles[1];
    g_fDeltaA[id] = g_fDeltaB[id];
    g_fDeltaB[id] = dBC;
    g_fErrA[id]   = g_fErrB[id];
    g_fErrB[id]   = err;
    g_fMvA[id][0] = g_fMvB[id][0];
    g_fMvA[id][1] = g_fMvB[id][1];
    g_fMvB[id][0] = fmove;
    g_fMvB[id][1] = smove;
    if (g_iAngHist[id] < 3)
        g_iAngHist[id]++;
    g_iLastMsecA[id]   = g_iLastMsec[id];
    g_iLastMsec[id]    = msec;
    g_iLastButtons[id] = buttons;
    return FMRES_IGNORED;
}
// Once per second
// VL decay, lag state and the per-second checks (speed, fps, pitch, spin).
public task_SecondCheck()
{
    CacheCvars();
    new tick = tickcount();
    g_iTickMs = tick - g_iLastTick;
    g_iLastTick = tick;
    g_bHitch = (g_iTickMs < 500 || g_iTickMs > 1500);
    if (g_iTickMs <= 0)
        g_iTickMs = 1000;
    new Float:decay     = CVF(CV_VL_DECAY) / 60.0;
    new secs            = CVI(CV_SEC_WINDOW);
    new speedLimit      = CVI(CV_SPEED_LIMIT);
    new Float:spinLimit = CVF(CV_SPIN_LIMIT);
    new Float:ratio     = CVF(CV_SPEED_RATIO);
    new lagPing         = CVI(CV_LAG_PING);
    new lagLoss         = CVI(CV_LAG_LOSS);
    if (secs < 1)
        secs = 1;
    if (secs > SEC_RING)
        secs = SEC_RING;
    new minValid = secs - 3;
    if (minValid < 5)
        minValid = (secs < 5) ? secs : 5;
    new players[32], num, id, ping, loss, s;
    new speedBad, spinBad, pitchSum, maxMsec, sumMsec, sumReal, valid, fpsBad, maxFps;
    new Float:avg;
    new detail[160];
    get_players(players, num, "ch");
    for (new i = 0; i < num; i++)
    {
        id = players[i];
        for (new f = 1; f < DETECT_TOTAL; f++)
        {
            g_fVL[id][f] -= decay;
            if (g_fVL[id][f] < 0.0)
                g_fVL[id][f] = 0.0;
        }
        get_user_ping(id, ping, loss);
        g_iPing[id] = ping;
        g_bLag[id] = (ping > lagPing || loss > lagLoss);
        s = g_iSecHead[id];
        g_iSecMsec[id][s]   = g_iMsec[id];
        g_iSecReal[id][s]   = g_iTickMs;
        g_iSecFrames[id][s] = g_iFrames[id];
        g_fSecYaw[id][s]    = g_fYawSum[id];
        g_iSecPitch[id][s]  = g_iPitchCount[id];
        g_bSecAlive[id][s]  = (is_user_alive(id) != 0);
        g_bSecLag[id][s]    = g_bLag[id] || g_bHitch;
        g_iSecHead[id]      = (s + 1) % SEC_RING;
        g_iMsec[id]       = 0;
        g_iFrames[id]     = 0;
        g_fYawSum[id]     = 0.0;
        g_iPitchCount[id] = 0;
        if (g_bKicked[id] || !g_bSecAlive[id][s])
            continue;
        SecStats(id, secs, speedLimit, spinLimit, speedBad, spinBad, pitchSum, maxMsec, sumMsec, sumReal, valid);
        if (CVI(CV_PITCH) && pitchSum >= CVI(CV_PITCH_WARNS))
        {
            formatex(detail, charsmax(detail), "invalid pitch: %d frames in %d sec, last %.1f",
                pitchSum, secs, g_fLastBadPitch[id]);
            Punish(id, DETECT_PITCH, detail);
            continue;
        }
        if (CVI(CV_SPEED))
        {
            avg = (sumReal > 0) ? float(sumMsec) / float(sumReal) : 0.0;
            if (speedBad >= CVI(CV_SPEED_WARNS))
            {
                formatex(detail, charsmax(detail), "speedhack: %d/%d sec over %d msec, max %d, avg x%.2f",
                    speedBad, secs, speedLimit, maxMsec, avg);
                AddViolation(id, DETECT_SPEED, detail, float(secs));
            }
            else if (ratio > 1.0 && valid >= minValid && avg >= ratio)
            {
                formatex(detail, charsmax(detail), "speedhack: game time x%.2f over %d sec (limit x%.2f)",
                    avg, valid, ratio);
                AddViolation(id, DETECT_SPEED, detail, float(secs));
            }
        }
        //if (CVI(CV_FPS))
        //{
        //    FpsStats(id, secs, CVI(CV_FPS_MAX), fpsBad, maxFps);
        //    if (fpsBad >= CVI(CV_FPS_WARNS))
        //    {
        //        formatex(detail, charsmax(detail), "high fps: %d/%d sec over %d, max %d",
        //            fpsBad, secs, CVI(CV_FPS_MAX), maxFps);
        //        AddViolation(id, DETECT_FPS, detail, float(secs));
        //    }
        //}
        if (CVI(CV_SPIN) && spinBad >= CVI(CV_SPIN_WARNS))
        {
            formatex(detail, charsmax(detail), "spinbot: %d/%d sec over %.0f deg/sec",
                spinBad, secs, spinLimit);
            AddViolation(id, DETECT_SPIN, detail, float(secs));
        }
    }
}
// Admin commands
ListPlayers(id)
{
    new players[32], num, pl, name[32], line[256], len, ping, loss;
    new Float:total;
    get_players(players, num, "ch");
    console_print(id, "[AC] %d players, punish mode %d (0 = log, 1 = kick, 2 = ban), kick at VL %.0f",
        num, CVI(CV_PUNISH), CVF(CV_VL_KICK));
    for (new i = 0; i < num; i++)
    {
        pl = players[i];
        get_user_name(pl, name, charsmax(name));
        get_user_ping(pl, ping, loss);
        total = 0.0;
        len = formatex(line, charsmax(line), "#%-4d %-24s ping %3d |", get_user_userid(pl), name, ping);
        for (new f = 1; f < DETECT_TOTAL; f++)
        {
            if (g_iWeightCv[f] < 0 || g_fVL[pl][f] < 1.0)
                continue;
            total += g_fVL[pl][f];
            len += formatex(line[len], charsmax(line) - len, " #%d=%.0f", f, g_fVL[pl][f]);
        }
        if (total < 1.0)
            len += formatex(line[len], charsmax(line) - len, " clean");
        if (IsImmune(pl))
            formatex(line[len], charsmax(line) - len, " (immune)");
        console_print(id, "%s", line);
    }
}
public cmd_Stats(id, level, cid)
{
    if (!cmd_access(id, level, cid, 1))
        return PLUGIN_HANDLED;
    if (read_argc() < 2)
    {
        ListPlayers(id);
        return PLUGIN_HANDLED;
    }
    new arg[32];
    read_argv(1, arg, charsmax(arg));
    new target = cmd_target(id, arg, CMDTARGET_ALLOW_SELF | CMDTARGET_NO_BOTS);
    if (!target)
        return PLUGIN_HANDLED;
    new name[32], ping, loss;
    get_user_name(target, name, charsmax(name));
    get_user_ping(target, ping, loss);
    new Float:window     = CVF(CV_WINDOW);
    new Float:jumpWindow = CVF(CV_JUMP_WINDOW);
    new Float:snapWindow = CVF(CV_SNAP_WINDOW);
    new Float:w;
    new t[STREAMS], h[STREAMS];
    for (new st = 0; st < STREAMS; st++)
    {
        if (st == ST_SNAP)
            w = snapWindow;
        else if (st == ST_SILENT || st == ST_SILENT_STRONG)
            w = CVF(CV_SILENT_WINDOW);
        else if (st == ST_SMOOTH)
            w = CVF(CV_SMOOTH_WINDOW);
        else if (st == ST_HS)
            w = CVF(CV_HS_WINDOW);
        else if (st == ST_AUTOSTOP)
            w = CVF(CV_AUTOSTOP_WINDOW);
        else if (st == ST_BHOP || st == ST_GSTRAFE || (st >= ST_BHOP_EXACT && st <= ST_DD_SPAM))
            w = jumpWindow;
        else
            w = window;
        CountStream(target, st, w, t[st], h[st]);
    }
    new secs = CVI(CV_SEC_WINDOW);
    new speedBad, spinBad, pitchSum, maxMsec, sumMsec, sumReal, valid, fpsBad, maxFps;
    SecStats(target, secs, CVI(CV_SPEED_LIMIT), CVF(CV_SPIN_LIMIT), speedBad, spinBad, pitchSum, maxMsec, sumMsec, sumReal, valid);
    FpsStats(target, secs, CVI(CV_FPS_MAX), fpsBad, maxFps);
    new Float:avg = (sumReal > 0) ? float(sumMsec) / float(sumReal) : 0.0;
    console_print(id, "[AC] %s | ping %d, loss %d%s", name, ping, loss, g_bLag[target] ? " (lag)" : "");
    console_print(id, "[AC] bhop: perfect %d/%d, exact %d/%d, tap %d/%d, spam %d/%d",
        h[ST_BHOP], t[ST_BHOP], h[ST_BHOP_EXACT], t[ST_BHOP_EXACT], h[ST_BHOP_TAP], t[ST_BHOP_TAP],
        h[ST_BHOP_SPAM], t[ST_BHOP_SPAM]);
    console_print(id, "[AC] dd/gstrafe: perfect %d/%d, exact %d/%d, tap %d/%d, spam %d/%d",
        h[ST_GSTRAFE], t[ST_GSTRAFE], h[ST_DD_EXACT], t[ST_DD_EXACT], h[ST_DD_TAP], t[ST_DD_TAP],
        h[ST_DD_SPAM], t[ST_DD_SPAM]);
    console_print(id, "[AC] strafe sync %d/%d, no-keys %d/%d, vector %d/%d, fast switch %d/%d",
        h[ST_STRAFE], t[ST_STRAFE], h[ST_NOKEYS], t[ST_NOKEYS], h[ST_VECTOR], t[ST_VECTOR], h[ST_FASTSW], t[ST_FASTSW]);
    console_print(id, "[AC] gcd %d/%d, recoil %d/%d, trigger %d/%d, autofire %d/%d",
        h[ST_GCD], t[ST_GCD], h[ST_RECOIL], t[ST_RECOIL], h[ST_TRIGGER], t[ST_TRIGGER], h[ST_AUTOFIRE], t[ST_AUTOFIRE]);
    new silentNeed = CVI(CV_SILENT_COUNT);
    if (silentNeed < 1)
        silentNeed = 1;
    new silentState[16];
    if (!CVI(CV_SILENT_INSTANT))
        copy(silentState, charsmax(silentState), ", instant off");
    else if (g_iVerifyLeft[target][VERIFY_SILENT] > 0)
        copy(silentState, charsmax(silentState), ", verifying");
    console_print(id, "[AC] snaps %d, silent %d (strong %d/%d%s), smooth %d, autostop frames %d, headshots %d/%d kills",
        h[ST_SNAP], h[ST_SILENT], h[ST_SILENT_STRONG], silentNeed, silentState,
        h[ST_SMOOTH], h[ST_AUTOSTOP], h[ST_HS], t[ST_HS]);
    console_print(id, "[AC] last %d sec: speed %d bad (max %d msec, avg x%.2f), spin %d bad, pitch %d frames, fps %d bad (max %d)",
        secs, speedBad, maxMsec, avg, spinBad, pitchSum, fpsBad, maxFps);
    console_print(id, "[AC] sens %.3f, m_yaw %.4f, m_filter %.0f, m_customaccel %.0f, ex_interp %.3f",
        g_fCl[target][CL_SENS], g_fCl[target][CL_MYAW], g_fCl[target][CL_MFILTER],
        g_fCl[target][CL_MACCEL], g_fCl[target][CL_INTERP]);
    new line[256], len;
    len = formatex(line, charsmax(line), "[AC] VL:");
    for (new f = 1; f < DETECT_TOTAL; f++)
    {
        if (g_iWeightCv[f] < 0)
            continue;
        len += formatex(line[len], charsmax(line) - len, " #%d=%.0f", f, g_fVL[target][f]);
    }
    console_print(id, "%s", line);
    return PLUGIN_HANDLED;
}
public cmd_Debug(id, level, cid)
{
    if (!cmd_access(id, level, cid, 2))
        return PLUGIN_HANDLED;
    new arg[32], arg2[8];
    read_argv(1, arg, charsmax(arg));
    read_argv(2, arg2, charsmax(arg2));
    new target = cmd_target(id, arg, CMDTARGET_ALLOW_SELF | CMDTARGET_NO_BOTS);
    if (!target)
        return PLUGIN_HANDLED;
    new Float:secs = arg2[0] ? floatstr(arg2) : 5.0;
    if (secs < 1.0)
        secs = 1.0;
    if (secs > 30.0)
        secs = 30.0;
    g_fDebugUntil[target] = get_gametime() + secs;
    new name[32];
    get_user_name(target, name, charsmax(name));
    console_print(id, "[AC] debug %s for %.0f sec -> logs/%s", name, secs, DEBUG_FILE);
    return PLUGIN_HANDLED;
}
public cmd_Reset(id, level, cid)
{
    if (!cmd_access(id, level, cid, 2))
        return PLUGIN_HANDLED;
    new arg[32];
    read_argv(1, arg, charsmax(arg));
    new target = cmd_target(id, arg, CMDTARGET_ALLOW_SELF | CMDTARGET_NO_BOTS);
    if (!target)
        return PLUGIN_HANDLED;
    for (new f = 0; f < DETECT_TOTAL; f++)
    {
        g_fVL[target][f]       = 0.0;
        g_fCooldown[target][f] = 0.0;
    }
    for (new st = 0; st < STREAMS; st++)
        ClearStream(target, st);
    for (new k = 0; k < VERIFY_KINDS; k++)
    {
        g_iVerifyLeft[target][k] = 0;
        remove_task(TASK_VERIFY + k * MAXP + target);
    }
    if (g_hVault != INVALID_HANDLE && g_szKey[target][0])
        nvault_remove(g_hVault, g_szKey[target]);
    new name[32];
    get_user_name(target, name, charsmax(name));
    console_print(id, "[AC] %s: VL and samples cleared", name);
    LogLine(target, "[Reset]", "VL and samples cleared by admin");
    return PLUGIN_HANDLED;
}
