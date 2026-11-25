#include <amxmodx>
#include <amxmisc>
#include <fakemeta>
#include <hlsdk_const>

#pragma tabsize 0

#define PLUGIN  "Simple AntiCheat"
#define VERSION "0.7"
#define AUTHOR  "Rust"

#define MAXP              33
#define TASK_CHECK        5100
#define TASK_SECOND       5200
#define TASK_QUERY        5300
#define LOG_FILE          "anticheat.log"
#define DEBUG_FILE        "ac_debug.log"

#define BHOP_CHAIN_MS     100
#define AUTOFIRE_MAX_MSEC 4
#define SPAWN_GRACE       1.5
#define CHECK_JITTER      0.3
#define VECTOR_MIN_MOVE   30.0
#define VECTOR_TOLERANCE  0.03
#define GCD_TOLERANCE     0.006
#define GCD_MIN_STEP      0.025
#define RECOIL_MIN_PUNCH  0.1
#define RECOIL_TOLERANCE  0.02
#define AUTOFIRE_MAX_GAP  400
#define WH_CACHE          0.1
#define WH_PREDICT        0.15
#define WH_NEAR           128.0
#define WH_SIDE           16.0

#define RING              64
#define SEC_RING          30
#define FRAMES            64

#define STREAMS           11
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

#define MOVE_GROUND       0
#define MOVE_AIR          1
#define MOVE_OTHER        2

#define CL_FWD            0
#define CL_BACK           1
#define CL_SIDE           2
#define CL_SENS           3
#define CL_MYAW           4
#define CL_MFILTER        5
#define CL_MACCEL         6
#define CL_INTERP         7
#define CL_TOTAL          8

#define BITS_NOGUN  ((1<<CSW_KNIFE)|(1<<CSW_HEGRENADE)|(1<<CSW_FLASHBANG)|(1<<CSW_SMOKEGRENADE)|(1<<CSW_C4))
#define BITS_PISTOL ((1<<CSW_GLOCK18)|(1<<CSW_USP)|(1<<CSW_P228)|(1<<CSW_DEAGLE)|(1<<CSW_ELITE)|(1<<CSW_FIVESEVEN))
#define BITS_AUTO   ((1<<CSW_MP5NAVY)|(1<<CSW_TMP)|(1<<CSW_P90)|(1<<CSW_MAC10)|(1<<CSW_UMP45)|(1<<CSW_AK47)|(1<<CSW_M4A1)|(1<<CSW_GALIL)|(1<<CSW_FAMAS)|(1<<CSW_SG552)|(1<<CSW_AUG)|(1<<CSW_M249))

#define CVF(%1) g_cv[%1]
#define CVI(%1) floatround(g_cv[%1])

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
    DETECT_TOTAL
};

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
    CV_LAG_PING,
    CV_LAG_LOSS,
    CV_SPEED,
    CV_SPEED_LIMIT,
    CV_SPEED_WARNS,
    CV_SPEED_VL,
    CV_QUERY,
    CV_QUERY_TIMEOUT,
    CV_QUERY_FAILS,
    CV_BHOP,
    CV_BHOP_JUMPS,
    CV_BHOP_PERCENT,
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
    CV_SNAP_STILL,
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
    CV_RECOIL,
    CV_RECOIL_SAMPLES,
    CV_RECOIL_PERCENT,
    CV_RECOIL_VL,
    CV_TRIGGER,
    CV_TRIGGER_MS,
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
    CV_ANTIWH,
    CV_TOTAL
};

new const g_szCheatCvars[][] =
{
    "ac_example_cheat_cvar_1",
    "ac_example_cheat_cvar_2"
};

new const g_szProtCvars[][] =
{
    "r_fullbright",
    "gl_wireframe",
    "r_drawentities",
    "gl_monolights"
};

new const Float:g_fProtAllowed[] =
{
    0.0,
    0.0,
    1.0,
    0.0
};

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

new const Float:g_fKeyRatios[] =
{
    0.25, 0.3333, 0.5, 0.6667, 0.75, 1.0, 1.3333, 1.5, 2.0, 3.0, 4.0
};

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

new g_pc[CV_TOTAL];
new Float:g_cv[CV_TOTAL];
new g_iWeightCv[DETECT_TOTAL];

new bool:g_bKicked[MAXP];
new bool:g_bIgnore[MAXP];
new bool:g_bWasAlive[MAXP];
new bool:g_bLag[MAXP];
new Float:g_fGraceUntil[MAXP];
new Float:g_fDebugUntil[MAXP];
new Float:g_fLastDump[MAXP];

new Float:g_fVL[MAXP][DETECT_TOTAL];
new Float:g_fMaxVL[MAXP][DETECT_TOTAL];
new Float:g_fCooldown[MAXP][DETECT_TOTAL];

new g_iMsec[MAXP];
new g_iFrames[MAXP];
new g_iClock[MAXP];
new Float:g_fYawSum[MAXP];
new g_iPitchCount[MAXP];
new Float:g_fLastBadPitch[MAXP];

new g_iSecMsec[MAXP][SEC_RING];
new g_iSecFrames[MAXP][SEC_RING];
new Float:g_fSecYaw[MAXP][SEC_RING];
new g_iSecPitch[MAXP][SEC_RING];
new bool:g_bSecAlive[MAXP][SEC_RING];
new bool:g_bSecLag[MAXP][SEC_RING];
new g_iSecHead[MAXP];

new Float:g_fEvTime[MAXP][STREAMS][RING];
new bool:g_bEvHit[MAXP][STREAMS][RING];
new g_iEvHead[MAXP][STREAMS];
new g_iEvFill[MAXP][STREAMS];

new g_iFrMove[MAXP][FRAMES];
new g_iFrMsec[MAXP][FRAMES];
new Float:g_fFrPitch[MAXP][FRAMES];
new Float:g_fFrYaw[MAXP][FRAMES];
new Float:g_fFrF[MAXP][FRAMES];
new Float:g_fFrS[MAXP][FRAMES];
new g_iFrBtn[MAXP][FRAMES];
new g_iFrHead[MAXP];
new g_iFrFill[MAXP];

new g_iAnswered[MAXP];
new g_iQueryFails[MAXP];
new Float:g_fCl[MAXP][CL_TOTAL];

new g_iGroundFrames[MAXP];
new g_iGroundMs[MAXP];
new g_iLastButtons[MAXP];

new Float:g_fAngA[MAXP][2];
new Float:g_fAngB[MAXP][2];
new Float:g_fDeltaA[MAXP];
new Float:g_fDeltaB[MAXP];
new g_iAngHist[MAXP];
new g_iLastMsec[MAXP];

new g_iLastMouseDir[MAXP];
new Float:g_fSegYaw[MAXP];
new g_iLastSideDir[MAXP];
new g_iLastSideSign[MAXP];
new g_iHoldMs[MAXP];

new Float:g_fLastPunch[MAXP];
new bool:g_bHasPunch[MAXP];
new bool:g_bOnTarget[MAXP];
new g_iTargetStart[MAXP];
new g_iLastPress[MAXP];
new g_iPrevInterval[MAXP];

new bool:g_bVisible[MAXP][MAXP];
new Float:g_fVisTime[MAXP][MAXP];

RegCvar(idx, const name[], const def[])
{
    g_pc[idx] = register_cvar(name, def);
}

CacheCvars()
{
    for (new i = 0; i < CV_TOTAL; i++)
        g_cv[i] = get_pcvar_float(g_pc[i]);
}

IntAbs(v)
{
    return (v < 0) ? -v : v;
}

Float:NormalizeAngle(Float:a)
{
    if (floatabs(a) > 100000.0)
        return 9999.0;

    return a - 360.0 * float(floatround(a / 360.0));
}

Float:AngleDist(Float:p1, Float:y1, Float:p2, Float:y2)
{
    new Float:dp = NormalizeAngle(p1 - p2);
    new Float:dy = NormalizeAngle(y1 - y2);
    return floatsqroot(dp * dp + dy * dy);
}

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

LogFile(const file[], const fmt[], any:...)
{
    new msg[256];
    vformat(msg, charsmax(msg), fmt, 3);

    if (CVI(CV_CONSOLE))
    {
        log_to_file(file, "%s", msg);
        return;
    }

    new path[128], date[32], line[300];
    get_localinfo("amxx_logs", path, charsmax(path));
    format(path, charsmax(path), "%s/%s", path, file);
    get_time("%m/%d/%Y - %H:%M:%S", date, charsmax(date));
    formatex(line, charsmax(line), "L %s: %s^n", date, msg);

    new f = fopen(path, "at");
    if (f)
    {
        fputs(f, line);
        fclose(f);
    }
}

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

NotifyKick(id, flag)
{
    if (!CVI(CV_NOTIFY))
        return;

    new name[32];
    get_user_name(id, name, charsmax(name));
    client_print(0, print_chat, "[AC] %s kicked: Detect #%d", name, flag);
}

Punish(id, flag, const detail[])
{
    if (g_bKicked[id])
        return;

    new prefix[24];

    if (IsImmune(id))
    {
        formatex(prefix, charsmax(prefix), "[Immune #%d]", flag);
        LogLine(id, prefix, detail);
        DumpFrames(id, prefix);
        return;
    }

    g_bKicked[id] = true;

    formatex(prefix, charsmax(prefix), "[Detect #%d]", flag);
    LogLine(id, prefix, detail);
    DumpFrames(id, prefix);
    NotifyKick(id, flag);

    server_cmd("kick #%d ^"Detect #%d^"", get_user_userid(id), flag);
}

AddViolation(id, flag, const detail[], Float:cooldown)
{
    if (g_bKicked[id] || g_iWeightCv[flag] < 0)
        return;

    new Float:now = get_gametime();
    if (now < g_fCooldown[id][flag])
        return;

    g_fCooldown[id][flag] = now + cooldown;

    g_fVL[id][flag] += CVF(g_iWeightCv[flag]);
    if (g_fVL[id][flag] > g_fMaxVL[id][flag])
        g_fMaxVL[id][flag] = g_fVL[id][flag];

    new Float:kick = CVF(CV_VL_KICK);
    new full[192];
    formatex(full, charsmax(full), "%s | VL %.0f/%.0f", detail, g_fVL[id][flag], kick);

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
}

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

CheckStreamFlag(id, st, flag, need, percent, const what[])
{
    new Float:window = CVF(CV_WINDOW);
    new total, hits, pct;

    if (!StreamTriggered(id, st, window, need, percent, total, hits, pct))
        return;

    new detail[160];
    formatex(detail, charsmax(detail), "%s: %d/%d (%d%%) in %.0f sec", what, hits, total, pct, window);

    ClearStream(id, st);
    AddViolation(id, flag, detail, 0.0);
}

SecStats(id, secs, speedLimit, Float:spinLimit, &speedBad, &spinBad, &pitchSum, &maxMsec)
{
    speedBad = 0;
    spinBad  = 0;
    pitchSum = 0;
    maxMsec  = 0;

    if (secs > SEC_RING)
        secs = SEC_RING;

    new s;

    for (new i = 1; i <= secs; i++)
    {
        s = (g_iSecHead[id] - i + SEC_RING) % SEC_RING;

        if (!g_bSecAlive[id][s])
            continue;

        pitchSum += g_iSecPitch[id][s];

        if (g_fSecYaw[id][s] > spinLimit)
            spinBad++;

        if (g_bSecLag[id][s])
            continue;

        if (g_iSecMsec[id][s] > maxMsec)
            maxMsec = g_iSecMsec[id][s];

        if (g_iSecMsec[id][s] > speedLimit)
            speedBad++;
    }
}

FpsStats(id, secs, fpsMax, &bad, &maxFps)
{
    bad    = 0;
    maxFps = 0;

    if (secs > SEC_RING)
        secs = SEC_RING;

    new s, fps;

    for (new i = 1; i <= secs; i++)
    {
        s = (g_iSecHead[id] - i + SEC_RING) % SEC_RING;

        if (!g_bSecAlive[id][s] || g_bSecLag[id][s] || g_iSecMsec[id][s] < 500)
            continue;

        fps = g_iSecFrames[id][s] * 1000 / g_iSecMsec[id][s];

        if (fps > maxFps)
            maxFps = fps;

        if (fps > fpsMax)
            bad++;
    }
}

public plugin_precache()
{
    new mins[3], maxs[3];

    for (new i = 0; i < sizeof g_szModels; i++)
        force_unmodified(force_model_samebounds, mins, maxs, g_szModels[i]);
}

public plugin_init()
{
    register_plugin(PLUGIN, VERSION, AUTHOR);

    RegCvar(CV_FIRST_CHECK,      "ac_first_check",        "10.0");
    RegCvar(CV_INTERVAL,         "ac_check_interval",     "60.0");
    RegCvar(CV_IMMUNITY,         "ac_immunity",           "0");
    RegCvar(CV_NOTIFY,           "ac_notify",             "1");
    RegCvar(CV_LOG_WARN,         "ac_log_warn",           "1");
    RegCvar(CV_SNAPSHOT,         "ac_snapshot",           "1");
    RegCvar(CV_CONSOLE,          "ac_console",            "0");

    RegCvar(CV_WINDOW,           "ac_window",             "60.0");
    RegCvar(CV_SEC_WINDOW,       "ac_sec_window",         "10");
    RegCvar(CV_VL_KICK,          "ac_vl_kick",            "100");
    RegCvar(CV_VL_DECAY,         "ac_vl_decay",           "3.0");
    RegCvar(CV_LAG_PING,         "ac_lag_ping",           "200");
    RegCvar(CV_LAG_LOSS,         "ac_lag_loss",           "5");

    RegCvar(CV_SPEED,            "ac_speed",              "1");
    RegCvar(CV_SPEED_LIMIT,      "ac_speed_limit",        "1200");
    RegCvar(CV_SPEED_WARNS,      "ac_speed_warns",        "4");
    RegCvar(CV_SPEED_VL,         "ac_speed_vl",           "60");

    RegCvar(CV_QUERY,            "ac_query",              "1");
    RegCvar(CV_QUERY_TIMEOUT,    "ac_query_timeout",      "15.0");
    RegCvar(CV_QUERY_FAILS,      "ac_query_fails",        "2");

    RegCvar(CV_BHOP,             "ac_bhop",               "1");
    RegCvar(CV_BHOP_JUMPS,       "ac_bhop_jumps",         "30");
    RegCvar(CV_BHOP_PERCENT,     "ac_bhop_percent",       "90");
    RegCvar(CV_BHOP_VL,          "ac_bhop_vl",            "60");

    RegCvar(CV_PITCH,            "ac_pitch",              "1");
    RegCvar(CV_PITCH_LIMIT,      "ac_pitch_limit",        "89.5");
    RegCvar(CV_PITCH_WARNS,      "ac_pitch_warns",        "20");

    RegCvar(CV_SPIN,             "ac_spin",               "1");
    RegCvar(CV_SPIN_LIMIT,       "ac_spin_limit",         "2880");
    RegCvar(CV_SPIN_WARNS,       "ac_spin_warns",         "3");
    RegCvar(CV_SPIN_VL,          "ac_spin_vl",            "60");

    RegCvar(CV_SNAP,             "ac_snap",               "1");
    RegCvar(CV_SNAP_ANGLE,       "ac_snap_angle",         "25.0");
    RegCvar(CV_SNAP_STILL,       "ac_snap_still",         "0.5");
    RegCvar(CV_SNAP_COUNT,       "ac_snap_count",         "4");
    RegCvar(CV_SNAP_WINDOW,      "ac_snap_window",        "120.0");
    RegCvar(CV_SNAP_VL,          "ac_snap_vl",            "60");

    RegCvar(CV_STRAFE,           "ac_strafe",             "1");
    RegCvar(CV_STRAFE_SAMPLES,   "ac_strafe_samples",     "40");
    RegCvar(CV_STRAFE_PERCENT,   "ac_strafe_percent",     "80");
    RegCvar(CV_STRAFE_MINTURN,   "ac_strafe_minturn",     "1.0");
    RegCvar(CV_STRAFE_VL,        "ac_strafe_vl",          "40");

    RegCvar(CV_GSTRAFE,          "ac_gstrafe",            "1");
    RegCvar(CV_GSTRAFE_DUCKS,    "ac_gstrafe_ducks",      "30");
    RegCvar(CV_GSTRAFE_PERCENT,  "ac_gstrafe_percent",    "90");
    RegCvar(CV_GSTRAFE_VL,       "ac_gstrafe_vl",         "60");

    RegCvar(CV_NOKEYS,           "ac_nokeys",             "1");
    RegCvar(CV_NOKEYS_SAMPLES,   "ac_nokeys_samples",     "50");
    RegCvar(CV_NOKEYS_PERCENT,   "ac_nokeys_percent",     "60");
    RegCvar(CV_NOKEYS_VL,        "ac_nokeys_vl",          "60");

    RegCvar(CV_VECTOR,           "ac_vector",             "1");
    RegCvar(CV_VECTOR_SAMPLES,   "ac_vector_samples",     "40");
    RegCvar(CV_VECTOR_PERCENT,   "ac_vector_percent",     "70");
    RegCvar(CV_VECTOR_VL,        "ac_vector_vl",          "60");

    RegCvar(CV_FS,               "ac_faststrafe",         "1");
    RegCvar(CV_FS_MS,            "ac_faststrafe_ms",      "20");
    RegCvar(CV_FS_SAMPLES,       "ac_faststrafe_samples", "20");
    RegCvar(CV_FS_PERCENT,       "ac_faststrafe_percent", "60");
    RegCvar(CV_FS_VL,            "ac_faststrafe_vl",      "60");

    RegCvar(CV_TRAP,             "ac_trap",               "1");

    RegCvar(CV_GCD,              "ac_gcd",                "1");
    RegCvar(CV_GCD_SAMPLES,      "ac_gcd_samples",        "60");
    RegCvar(CV_GCD_PERCENT,      "ac_gcd_percent",        "40");
    RegCvar(CV_GCD_VL,           "ac_gcd_vl",             "50");

    RegCvar(CV_RECOIL,           "ac_norecoil",           "1");
    RegCvar(CV_RECOIL_SAMPLES,   "ac_norecoil_samples",   "30");
    RegCvar(CV_RECOIL_PERCENT,   "ac_norecoil_percent",   "80");
    RegCvar(CV_RECOIL_VL,        "ac_norecoil_vl",        "60");

    RegCvar(CV_TRIGGER,          "ac_trigger",            "1");
    RegCvar(CV_TRIGGER_MS,       "ac_trigger_ms",         "40");
    RegCvar(CV_TRIGGER_SAMPLES,  "ac_trigger_samples",    "15");
    RegCvar(CV_TRIGGER_PERCENT,  "ac_trigger_percent",    "70");
    RegCvar(CV_TRIGGER_VL,       "ac_trigger_vl",         "60");

    RegCvar(CV_AUTOFIRE,         "ac_autofire",           "1");
    RegCvar(CV_AUTOFIRE_SAMPLES, "ac_autofire_samples",   "20");
    RegCvar(CV_AUTOFIRE_PERCENT, "ac_autofire_percent",   "80");
    RegCvar(CV_AUTOFIRE_VL,      "ac_autofire_vl",        "60");

    RegCvar(CV_FPS,              "ac_fps",                "1");
    RegCvar(CV_FPS_MAX,          "ac_fps_max",            "105");
    RegCvar(CV_FPS_WARNS,        "ac_fps_warns",          "5");
    RegCvar(CV_FPS_VL,           "ac_fps_vl",             "50");

    RegCvar(CV_ANTIWH,           "ac_antiwh",             "1");

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

    register_concmd("amx_acstats", "cmd_Stats", ADMIN_BAN, "<name|#userid>");
    register_concmd("amx_acdebug", "cmd_Debug", ADMIN_RCON, "<name|#userid> [seconds]");

    register_forward(FM_CmdStart, "fw_CmdStart");
    register_forward(FM_AddToFullPack, "fw_AddToFullPack", 0);
    register_event("HLTV", "ev_NewRound", "a", "1=0", "2=0");

    CacheCvars();
    set_task(1.0, "task_SecondCheck", TASK_SECOND, _, _, "b");
}

public plugin_cfg()
{
    CacheCvars();
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

    g_iMsec[id]         = 0;
    g_iFrames[id]       = 0;
    g_iClock[id]        = 0;
    g_fYawSum[id]       = 0.0;
    g_iPitchCount[id]   = 0;
    g_fLastBadPitch[id] = 0.0;

    g_iAnswered[id]     = 0;
    g_iQueryFails[id]   = 0;

    for (new c = 0; c < CL_TOTAL; c++)
        g_fCl[id][c] = g_fClientDefault[c];

    g_iGroundFrames[id] = 0;
    g_iGroundMs[id]     = 0;
    g_iLastButtons[id]  = 0;
    g_iAngHist[id]      = 0;
    g_fDeltaA[id]       = 0.0;
    g_fDeltaB[id]       = 0.0;
    g_iLastMsec[id]     = 0;
    g_iLastMouseDir[id] = 0;
    g_fSegYaw[id]       = 0.0;
    g_iLastSideDir[id]  = 0;
    g_iLastSideSign[id] = 0;
    g_iHoldMs[id]       = 0;

    g_fLastPunch[id]    = 0.0;
    g_bHasPunch[id]     = false;
    g_bOnTarget[id]     = false;
    g_iTargetStart[id]  = 0;
    g_iLastPress[id]    = 0;
    g_iPrevInterval[id] = 0;

    g_iFrHead[id] = 0;
    g_iFrFill[id] = 0;

    for (new f = 0; f < DETECT_TOTAL; f++)
    {
        g_fVL[id][f]       = 0.0;
        g_fMaxVL[id][f]    = 0.0;
        g_fCooldown[id][f] = 0.0;
    }

    for (new s = 0; s < SEC_RING; s++)
    {
        g_iSecMsec[id][s]   = 0;
        g_iSecFrames[id][s] = 0;
        g_fSecYaw[id][s]    = 0.0;
        g_iSecPitch[id][s]  = 0;
        g_bSecAlive[id][s]  = false;
        g_bSecLag[id][s]    = false;
    }
    g_iSecHead[id] = 0;

    for (new st = 0; st < STREAMS; st++)
        ClearStream(id, st);

    for (new p = 0; p < MAXP; p++)
    {
        g_bVisible[id][p] = true;
        g_bVisible[p][id] = true;
        g_fVisTime[id][p] = 0.0;
        g_fVisTime[p][id] = 0.0;
    }
}

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

public client_connect(id)
{
    ResetPlayer(id);
}

public client_putinserver(id)
{
    if (is_user_bot(id) || is_user_hltv(id))
    {
        g_bIgnore[id] = true;
        return;
    }

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

    if (!g_bIgnore[id])
        LogSession(id);

    ResetPlayer(id);
}

public ev_NewRound()
{
    new Float:until = get_gametime() + SPAWN_GRACE;

    for (new id = 1; id < MAXP; id++)
    {
        g_fGraceUntil[id] = until;
        g_iAngHist[id]    = 0;
        g_bHasPunch[id]   = false;
    }
}

public task_CvarCheck(taskid)
{
    new id = taskid - TASK_CHECK;

    if (!is_user_connected(id) || g_bKicked[id])
        return;

    g_iAnswered[id] = 0;

    new param[1];

    for (new i = 0; i < sizeof g_szCheatCvars; i++)
    {
        param[0] = i;
        query_client_cvar(id, g_szCheatCvars[i], "cb_CheatCvar", 1, param);
    }

    for (new i = 0; i < sizeof g_szProtCvars; i++)
    {
        param[0] = i;
        query_client_cvar(id, g_szProtCvars[i], "cb_ProtCvar", 1, param);
    }

    for (new i = 0; i < CL_TOTAL; i++)
    {
        param[0] = i;
        query_client_cvar(id, g_szClientCvars[i], "cb_ClientCvar", 1, param);
    }

    if (CVI(CV_TRAP))
    {
        new fake[32];
        formatex(fake, charsmax(fake), "ac_%d_%d", random_num(10000, 99999), random_num(10000, 99999));
        param[0] = 0;
        query_client_cvar(id, fake, "cb_Trap", 1, param);
    }

    if (CVI(CV_QUERY))
    {
        remove_task(id + TASK_QUERY);
        set_task(CVF(CV_QUERY_TIMEOUT), "task_QueryTimeout", id + TASK_QUERY);
    }

    new Float:next = CVF(CV_INTERVAL) * random_float(1.0 - CHECK_JITTER, 1.0 + CHECK_JITTER);
    set_task(next, "task_CvarCheck", taskid);
}

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

public cb_ProtCvar(id, const cvar[], const value[], const param[])
{
    if (!is_user_connected(id))
        return;

    g_iAnswered[id]++;

    if (g_bKicked[id] || equal(value, "Bad CVAR request"))
        return;

    new idx = param[0];
    if (floatabs(floatstr(value) - g_fProtAllowed[idx]) > 0.001)
    {
        new detail[128];
        formatex(detail, charsmax(detail), "%s = ^"%s^" (allowed %.1f)", cvar, value, g_fProtAllowed[idx]);
        Punish(id, DETECT_BAD_VALUE, detail);
    }
}

public cb_ClientCvar(id, const cvar[], const value[], const param[])
{
    if (!is_user_connected(id))
        return;

    g_iAnswered[id]++;

    new idx = param[0];

    if (equal(value, "Bad CVAR request"))
    {
        if (idx == CL_SENS && CVI(CV_TRAP) && !g_bKicked[id])
            Punish(id, DETECT_TRAP, "real cvar ^"sensitivity^" reported as missing");
        return;
    }

    new Float:v = floatstr(value);

    if (idx <= CL_SIDE && v <= 0.0)
        return;

    g_fCl[id][idx] = v;
}

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

    g_iQueryFails[id]++;

    if (g_iQueryFails[id] >= CVI(CV_QUERY_FAILS))
    {
        new detail[128];
        formatex(detail, charsmax(detail), "no answer to cvar queries, %d checks in a row", g_iQueryFails[id]);
        Punish(id, DETECT_NO_QUERY, detail);
        return;
    }

    remove_task(id + TASK_CHECK);
    set_task(1.0, "task_CvarCheck", id + TASK_CHECK);
}

public inconsistent_file(id, const filename[], reason[64])
{
    new detail[128], prefix[24];
    formatex(detail, charsmax(detail), "inconsistent file: %s", filename);

    if (IsImmune(id))
    {
        formatex(prefix, charsmax(prefix), "[Immune #%d]", DETECT_FILE);
        LogLine(id, prefix, detail);
        return PLUGIN_HANDLED;
    }

    g_bKicked[id] = true;

    formatex(prefix, charsmax(prefix), "[Detect #%d]", DETECT_FILE);
    LogLine(id, prefix, detail);
    NotifyKick(id, DETECT_FILE);

    formatex(reason, 63, "Detect #%d", DETECT_FILE);
    return PLUGIN_CONTINUE;
}

UpdateGround(id, msec)
{
    if (pev(id, pev_movetype) == MOVETYPE_FLY || pev(id, pev_waterlevel) >= 2)
    {
        g_iGroundFrames[id] = 0;
        g_iGroundMs[id]     = 0;
        return MOVE_OTHER;
    }

    if (!(pev(id, pev_flags) & FL_ONGROUND))
    {
        g_iGroundFrames[id] = 0;
        g_iGroundMs[id]     = 0;
        return MOVE_AIR;
    }

    g_iGroundFrames[id]++;
    g_iGroundMs[id] += msec;
    return MOVE_GROUND;
}

CheckPerfectPress(id, buttons, st)
{
    new button = (st == ST_BHOP) ? IN_JUMP : IN_DUCK;

    if (!(buttons & button) || (g_iLastButtons[id] & button))
        return;

    if (g_iGroundMs[id] > BHOP_CHAIN_MS)
        return;

    PushEvent(id, st, g_iGroundFrames[id] == 1);

    if (st == ST_BHOP)
        CheckStreamFlag(id, st, DETECT_BHOP, CVI(CV_BHOP_JUMPS), CVI(CV_BHOP_PERCENT), "bhop script, perfect jumps");
    else
        CheckStreamFlag(id, st, DETECT_GSTRAFE, CVI(CV_GSTRAFE_DUCKS), CVI(CV_GSTRAFE_PERCENT), "gstrafe script, perfect ducks");
}

CheckSnap(id, Float:pitchC, Float:yawC, Float:dBC, buttons)
{
    new Float:snap  = CVF(CV_SNAP_ANGLE);
    new Float:still = CVF(CV_SNAP_STILL);
    new Float:dAB   = g_fDeltaB[id];

    if (dAB < snap || g_fDeltaA[id] > still)
        return;

    if (g_iLastMsec[id] <= 0 || g_iLastMsec[id] > 20)
        return;

    if (g_bLag[id])
        return;

    new bool:attackB = (g_iLastButtons[id] & IN_ATTACK) != 0;
    new bool:attackC = (buttons & IN_ATTACK) != 0;
    new kind[16];

    if (dBC < still && (attackB || attackC))
        copy(kind, charsmax(kind), "snap-stop");
    else if (attackB && AngleDist(pitchC, yawC, g_fAngA[id][0], g_fAngA[id][1]) < still * 2.0)
        copy(kind, charsmax(kind), "snap-return");
    else
        return;

    PushEvent(id, ST_SNAP, true);

    new Float:window = CVF(CV_SNAP_WINDOW);
    new total, hits;
    CountStream(id, ST_SNAP, window, total, hits);

    if (hits < CVI(CV_SNAP_COUNT))
        return;

    new detail[128];
    formatex(detail, charsmax(detail), "aim %s: %d snaps in %.0f sec, last %.1f deg",
        kind, hits, window, dAB);

    ClearStream(id, ST_SNAP);
    AddViolation(id, DETECT_SNAP, detail, 0.0);
}

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

CheckNoKeys(id, Float:fmove, Float:smove, buttons)
{
    new bool:any = false;
    new bool:bad = false;

    if (floatabs(smove) >= 1.0)
    {
        any = true;

        if (smove < 0.0 && !(buttons & (IN_MOVELEFT | IN_LEFT)))
            bad = true;
        else if (smove > 0.0 && !(buttons & (IN_MOVERIGHT | IN_RIGHT)))
            bad = true;
    }

    if (floatabs(fmove) >= 1.0)
    {
        any = true;

        if (fmove > 0.0 && !(buttons & IN_FORWARD))
            bad = true;
        else if (fmove < 0.0 && !(buttons & IN_BACK))
            bad = true;
    }

    if (!any)
        return;

    PushEvent(id, ST_NOKEYS, bad);

    if (bad)
        CheckStreamFlag(id, ST_NOKEYS, DETECT_NOKEYS, CVI(CV_NOKEYS_SAMPLES), CVI(CV_NOKEYS_PERCENT),
            "move without keys, frames");
}

bool:IsKeyboardRatio(id, Float:fmove, Float:smove)
{
    new Float:fwd  = (fmove > 0.0) ? g_fCl[id][CL_FWD] : g_fCl[id][CL_BACK];
    new Float:side = g_fCl[id][CL_SIDE];

    if (fwd <= 0.0 || side <= 0.0)
        return true;

    new Float:r = (floatabs(fmove) / floatabs(smove)) / (fwd / side);

    for (new i = 0; i < sizeof g_fKeyRatios; i++)
    {
        if (floatabs(r - g_fKeyRatios[i]) <= g_fKeyRatios[i] * VECTOR_TOLERANCE)
            return true;
    }

    return false;
}

CheckVector(id, Float:fmove, Float:smove)
{
    if (floatabs(fmove) < VECTOR_MIN_MOVE || floatabs(smove) < VECTOR_MIN_MOVE)
        return;

    new bool:bad = !IsKeyboardRatio(id, fmove, smove);
    PushEvent(id, ST_VECTOR, bad);

    if (bad)
        CheckStreamFlag(id, ST_VECTOR, DETECT_VECTOR, CVI(CV_VECTOR_SAMPLES), CVI(CV_VECTOR_PERCENT),
            "non-keyboard move vector, frames");
}

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

CheckGcd(id, Float:dyaw, buttons)
{
    if (buttons & (IN_LEFT | IN_RIGHT))
        return;

    if (g_fCl[id][CL_MFILTER] != 0.0 || g_fCl[id][CL_MACCEL] != 0.0)
        return;

    new Float:fov;
    pev(id, pev_fov, fov);
    if (fov > 0.0 && fov < 89.0)
        return;

    new Float:step = g_fCl[id][CL_SENS] * floatabs(g_fCl[id][CL_MYAW]);
    if (step < GCD_MIN_STEP)
        return;

    new Float:ad = floatabs(dyaw);
    if (ad < step || ad > 30.0)
        return;

    new Float:rem = floatabs(ad - step * float(floatround(ad / step)));
    new bool:bad = (rem > GCD_TOLERANCE);

    PushEvent(id, ST_GCD, bad);

    if (bad)
        CheckStreamFlag(id, ST_GCD, DETECT_GCD, CVI(CV_GCD_SAMPLES), CVI(CV_GCD_PERCENT),
            "aim gcd, off-step turns");
}

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

bool:AimOnEnemy(id, const Float:angles[3])
{
    new Float:start[3], Float:ofs[3], Float:fwd[3], Float:end[3];

    pev(id, pev_origin, start);
    pev(id, pev_view_ofs, ofs);

    for (new i = 0; i < 3; i++)
        start[i] += ofs[i];

    engfunc(EngFunc_MakeVectors, angles);
    global_get(glb_v_forward, fwd);

    for (new i = 0; i < 3; i++)
        end[i] = start[i] + fwd[i] * 8192.0;

    engfunc(EngFunc_TraceLine, start, end, DONT_IGNORE_MONSTERS, id, 0);

    new hit = get_tr2(0, TR_pHit);

    if (hit < 1 || hit > 32 || !is_user_alive(hit))
        return false;

    return (get_user_team(hit) != get_user_team(id));
}

CheckTrigger(id, const Float:angles[3], buttons, weapon)
{
    new bool:on = false;

    if (weapon > 0 && !WeaponIn(weapon, BITS_NOGUN))
        on = AimOnEnemy(id, angles);

    if (on && !g_bOnTarget[id])
        g_iTargetStart[id] = g_iClock[id];

    g_bOnTarget[id] = on;

    if (!on || !(buttons & IN_ATTACK) || (g_iLastButtons[id] & IN_ATTACK))
        return;

    new ping, loss;
    get_user_ping(id, ping, loss);

    new lerp = floatround(g_fCl[id][CL_INTERP] * 1000.0);
    if (lerp < 0)
        lerp = 0;
    if (lerp > 100)
        lerp = 100;

    new reaction = g_iClock[id] - g_iTargetStart[id];
    new bool:hit = (reaction <= CVI(CV_TRIGGER_MS) + ping + lerp);

    PushEvent(id, ST_TRIGGER, hit);

    if (hit)
        CheckStreamFlag(id, ST_TRIGGER, DETECT_TRIGGER, CVI(CV_TRIGGER_SAMPLES), CVI(CV_TRIGGER_PERCENT),
            "triggerbot, instant shots");
}

CheckAutofire(id, buttons, weapon, msec)
{
    if (!(buttons & IN_ATTACK) || (g_iLastButtons[id] & IN_ATTACK))
        return;

    if (!WeaponIn(weapon, BITS_PISTOL))
    {
        g_iLastPress[id]    = 0;
        g_iPrevInterval[id] = 0;
        return;
    }

    new interval = g_iClock[id] - g_iLastPress[id];
    g_iLastPress[id] = g_iClock[id];

    if (interval > AUTOFIRE_MAX_GAP)
    {
        g_iPrevInterval[id] = 0;
        return;
    }

    if (g_iPrevInterval[id] <= 0 || msec > AUTOFIRE_MAX_MSEC)
    {
        g_iPrevInterval[id] = interval;
        return;
    }

    new bool:hit = (IntAbs(interval - g_iPrevInterval[id]) <= 1);
    g_iPrevInterval[id] = interval;

    PushEvent(id, ST_AUTOFIRE, hit);

    if (hit)
        CheckStreamFlag(id, ST_AUTOFIRE, DETECT_AUTOFIRE, CVI(CV_AUTOFIRE_SAMPLES), CVI(CV_AUTOFIRE_PERCENT),
            "autofire, equal click intervals");
}

public fw_CmdStart(id, uc_handle, seed)
{
    if (g_bIgnore[id] || g_bKicked[id])
        return FMRES_IGNORED;

    if (!is_user_alive(id))
    {
        g_bWasAlive[id] = false;
        return FMRES_IGNORED;
    }

    if (!g_bWasAlive[id])
    {
        g_bWasAlive[id]     = true;
        g_iAngHist[id]      = 0;
        g_iGroundFrames[id] = 0;
        g_iGroundMs[id]     = 0;
        g_iLastMouseDir[id] = 0;
        g_iLastSideSign[id] = 0;
        g_bHasPunch[id]     = false;
        g_bOnTarget[id]     = false;
        g_iLastPress[id]    = 0;
        g_iPrevInterval[id] = 0;
        g_fGraceUntil[id]   = get_gametime() + SPAWN_GRACE;
    }

    new msec    = get_uc(uc_handle, UC_Msec);
    new buttons = get_uc(uc_handle, UC_Buttons);
    new weapon  = get_user_weapon(id);

    new Float:angles[3];
    get_uc(uc_handle, UC_ViewAngles, angles);

    new Float:fmove, Float:smove;
    get_uc(uc_handle, UC_ForwardMove, fmove);
    get_uc(uc_handle, UC_SideMove, smove);

    g_iMsec[id]  += msec;
    g_iClock[id] += msec;
    g_iFrames[id]++;

    new bool:grace = (get_gametime() <= g_fGraceUntil[id]);
    new moveType = UpdateGround(id, msec);

    if (moveType == MOVE_GROUND)
    {
        if (CVI(CV_BHOP))
            CheckPerfectPress(id, buttons, ST_BHOP);
        if (CVI(CV_GSTRAFE))
            CheckPerfectPress(id, buttons, ST_GSTRAFE);
    }

    if (moveType != MOVE_OTHER && CVI(CV_NOKEYS))
        CheckNoKeys(id, fmove, smove, buttons);

    if (moveType == MOVE_AIR)
    {
        if (CVI(CV_VECTOR))
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

    if (CVI(CV_TRIGGER) && !grace && !g_bLag[id])
        CheckTrigger(id, angles, buttons, weapon);

    if (CVI(CV_AUTOFIRE))
        CheckAutofire(id, buttons, weapon, msec);

    new Float:dBC  = 0.0;
    new Float:dyaw = 0.0;

    if (g_iAngHist[id] > 0)
    {
        dyaw = NormalizeAngle(angles[1] - g_fAngB[id][1]);
        dBC  = AngleDist(angles[0], angles[1], g_fAngB[id][0], g_fAngB[id][1]);

        g_fYawSum[id] += floatabs(dyaw);

        if (moveType == MOVE_AIR && CVI(CV_STRAFE))
            CheckStrafe(id, dyaw, smove);

        if (!grace && CVI(CV_GCD))
            CheckGcd(id, dyaw, buttons);

        if (g_iAngHist[id] >= 3 && CVI(CV_SNAP) && !grace)
            CheckSnap(id, angles[0], angles[1], dBC, buttons);
    }

    if (moveType != MOVE_AIR)
    {
        g_iLastMouseDir[id] = 0;
        g_fSegYaw[id]       = 0.0;
    }

    RecordFrame(id, moveType, msec, angles[0], angles[1], fmove, smove, buttons);

    if (g_fDebugUntil[id] > get_gametime())
    {
        new name[32], line[160];
        get_user_name(id, name, charsmax(name));
        FormatFrame(line, charsmax(line), moveType, msec, angles[0], angles[1], fmove, smove, buttons);
        LogFile(DEBUG_FILE, "%s | %s dyaw=%.3f", name, line, dyaw);
    }

    g_iLastSideDir[id] = SideDir(smove);

    g_fAngA[id][0] = g_fAngB[id][0];
    g_fAngA[id][1] = g_fAngB[id][1];
    g_fAngB[id][0] = angles[0];
    g_fAngB[id][1] = angles[1];

    g_fDeltaA[id] = g_fDeltaB[id];
    g_fDeltaB[id] = dBC;

    if (g_iAngHist[id] < 3)
        g_iAngHist[id]++;

    g_iLastMsec[id]    = msec;
    g_iLastButtons[id] = buttons;

    return FMRES_IGNORED;
}

bool:TraceClear(skip, const Float:from[3], const Float:to[3])
{
    engfunc(EngFunc_TraceLine, from, to, IGNORE_MONSTERS | IGNORE_GLASS, skip, 0);

    new Float:frac;
    get_tr2(0, TR_flFraction, frac);

    return (frac >= 1.0);
}

bool:IsVisible(host, ent)
{
    new Float:eye[3], Float:ofs[3], Float:vel[3], Float:org[3], Float:evel[3];

    pev(host, pev_origin, eye);
    pev(host, pev_view_ofs, ofs);
    pev(host, pev_velocity, vel);
    pev(ent, pev_origin, org);
    pev(ent, pev_velocity, evel);

    for (new i = 0; i < 3; i++)
        eye[i] += ofs[i];

    new Float:dx = org[0] - eye[0];
    new Float:dy = org[1] - eye[1];
    new Float:dz = org[2] - eye[2];
    new Float:dist = floatsqroot(dx * dx + dy * dy + dz * dz);

    if (dist < WH_NEAR)
        return true;

    new Float:flat = floatsqroot(dx * dx + dy * dy);
    if (flat < 1.0)
        flat = 1.0;

    new Float:rx = -dy / flat * WH_SIDE;
    new Float:ry =  dx / flat * WH_SIDE;

    new Float:eyes[2][3];
    new Float:pts[6][3];

    for (new i = 0; i < 3; i++)
    {
        eyes[0][i] = eye[i];
        eyes[1][i] = eye[i] + vel[i] * WH_PREDICT;

        pts[0][i] = org[i];
        pts[1][i] = org[i];
        pts[2][i] = org[i];
        pts[3][i] = org[i];
        pts[4][i] = org[i];
        pts[5][i] = org[i] + evel[i] * WH_PREDICT;
    }

    pts[1][2] += 28.0;
    pts[2][2] -= 28.0;
    pts[3][0] += rx;
    pts[3][1] += ry;
    pts[4][0] -= rx;
    pts[4][1] -= ry;

    for (new e = 0; e < 2; e++)
    {
        for (new p = 0; p < 6; p++)
        {
            if (TraceClear(host, eyes[e], pts[p]))
                return true;
        }
    }

    return false;
}

public fw_AddToFullPack(es, e, ent, host, hostflags, player, pSet)
{
    if (!player || !CVI(CV_ANTIWH) || ent == host)
        return FMRES_IGNORED;

    if (host < 1 || host > 32 || ent < 1 || ent > 32)
        return FMRES_IGNORED;

    if (g_bIgnore[host] || !is_user_alive(host) || !is_user_alive(ent))
        return FMRES_IGNORED;

    if (get_user_team(host) == get_user_team(ent))
        return FMRES_IGNORED;

    new Float:now = get_gametime();

    if (now >= g_fVisTime[host][ent])
    {
        g_bVisible[host][ent] = IsVisible(host, ent);
        g_fVisTime[host][ent] = now + WH_CACHE;
    }

    if (g_bVisible[host][ent])
        return FMRES_IGNORED;

    forward_return(FMV_CELL, 0);
    return FMRES_SUPERCEDE;
}

public task_SecondCheck()
{
    CacheCvars();

    new Float:decay     = CVF(CV_VL_DECAY) / 60.0;
    new secs            = CVI(CV_SEC_WINDOW);
    new speedLimit      = CVI(CV_SPEED_LIMIT);
    new Float:spinLimit = CVF(CV_SPIN_LIMIT);
    new lagPing         = CVI(CV_LAG_PING);
    new lagLoss         = CVI(CV_LAG_LOSS);

    if (secs < 1)
        secs = 1;
    if (secs > SEC_RING)
        secs = SEC_RING;

    new players[32], num, id, ping, loss, s;
    new speedBad, spinBad, pitchSum, maxMsec, fpsBad, maxFps;
    new detail[128];

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
        g_bLag[id] = (ping > lagPing || loss > lagLoss);

        s = g_iSecHead[id];
        g_iSecMsec[id][s]   = g_iMsec[id];
        g_iSecFrames[id][s] = g_iFrames[id];
        g_fSecYaw[id][s]    = g_fYawSum[id];
        g_iSecPitch[id][s]  = g_iPitchCount[id];
        g_bSecAlive[id][s]  = (is_user_alive(id) != 0);
        g_bSecLag[id][s]    = g_bLag[id];
        g_iSecHead[id]      = (s + 1) % SEC_RING;

        g_iMsec[id]       = 0;
        g_iFrames[id]     = 0;
        g_fYawSum[id]     = 0.0;
        g_iPitchCount[id] = 0;

        if (g_bKicked[id] || !g_bSecAlive[id][s])
            continue;

        SecStats(id, secs, speedLimit, spinLimit, speedBad, spinBad, pitchSum, maxMsec);

        if (CVI(CV_PITCH) && pitchSum >= CVI(CV_PITCH_WARNS))
        {
            formatex(detail, charsmax(detail), "invalid pitch: %d frames in %d sec, last %.1f",
                pitchSum, secs, g_fLastBadPitch[id]);
            Punish(id, DETECT_PITCH, detail);
            continue;
        }

        if (CVI(CV_SPEED) && speedBad >= CVI(CV_SPEED_WARNS))
        {
            formatex(detail, charsmax(detail), "speedhack: %d/%d sec over %d msec, max %d",
                speedBad, secs, speedLimit, maxMsec);
            AddViolation(id, DETECT_SPEED, detail, float(secs));
        }

        if (CVI(CV_FPS))
        {
            FpsStats(id, secs, CVI(CV_FPS_MAX), fpsBad, maxFps);

            if (fpsBad >= CVI(CV_FPS_WARNS))
            {
                formatex(detail, charsmax(detail), "high fps: %d/%d sec over %d, max %d",
                    fpsBad, secs, CVI(CV_FPS_MAX), maxFps);
                AddViolation(id, DETECT_FPS, detail, float(secs));
            }
        }

        if (CVI(CV_SPIN) && spinBad >= CVI(CV_SPIN_WARNS))
        {
            formatex(detail, charsmax(detail), "spinbot: %d/%d sec over %.0f deg/sec",
                spinBad, secs, spinLimit);
            AddViolation(id, DETECT_SPIN, detail, float(secs));
        }
    }
}

public cmd_Stats(id, level, cid)
{
    if (!cmd_access(id, level, cid, 2))
        return PLUGIN_HANDLED;

    new arg[32];
    read_argv(1, arg, charsmax(arg));

    new target = cmd_target(id, arg, CMDTARGET_ALLOW_SELF | CMDTARGET_NO_BOTS);
    if (!target)
        return PLUGIN_HANDLED;

    new name[32], ping, loss;
    get_user_name(target, name, charsmax(name));
    get_user_ping(target, ping, loss);

    new Float:window     = CVF(CV_WINDOW);
    new Float:snapWindow = CVF(CV_SNAP_WINDOW);
    new t[STREAMS], h[STREAMS];

    for (new st = 0; st < STREAMS; st++)
        CountStream(target, st, (st == ST_SNAP) ? snapWindow : window, t[st], h[st]);

    new secs = CVI(CV_SEC_WINDOW);
    new speedBad, spinBad, pitchSum, maxMsec, fpsBad, maxFps;
    SecStats(target, secs, CVI(CV_SPEED_LIMIT), CVF(CV_SPIN_LIMIT), speedBad, spinBad, pitchSum, maxMsec);
    FpsStats(target, secs, CVI(CV_FPS_MAX), fpsBad, maxFps);

    console_print(id, "[AC] %s | ping %d, loss %d%s", name, ping, loss, g_bLag[target] ? " (lag)" : "");
    console_print(id, "[AC] bhop %d/%d, gstrafe %d/%d, strafe sync %d/%d",
        h[ST_BHOP], t[ST_BHOP], h[ST_GSTRAFE], t[ST_GSTRAFE], h[ST_STRAFE], t[ST_STRAFE]);
    console_print(id, "[AC] no-keys %d/%d, vector %d/%d, fast switch %d/%d",
        h[ST_NOKEYS], t[ST_NOKEYS], h[ST_VECTOR], t[ST_VECTOR], h[ST_FASTSW], t[ST_FASTSW]);
    console_print(id, "[AC] gcd %d/%d, recoil %d/%d, trigger %d/%d, autofire %d/%d",
        h[ST_GCD], t[ST_GCD], h[ST_RECOIL], t[ST_RECOIL], h[ST_TRIGGER], t[ST_TRIGGER], h[ST_AUTOFIRE], t[ST_AUTOFIRE]);
    console_print(id, "[AC] snaps: %d in %.0f sec", h[ST_SNAP], snapWindow);
    console_print(id, "[AC] last %d sec: speed %d bad (max %d msec), spin %d bad, pitch %d frames, fps %d bad (max %d)",
        secs, speedBad, maxMsec, spinBad, pitchSum, fpsBad, maxFps);
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