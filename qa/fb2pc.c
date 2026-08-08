/* fb2pc - the two-phase-commit probe. isql cannot speak 2PC, so this
 * is the client: start a transaction, write, PREPARE, and then either
 * exit without resolving (leaving a LIMBO transaction for gfix to
 * find), or commit/rollback after prepare, or reconnect a limbo id and
 * resolve it - each a law the conversion must match.
 *
 *   fb2pc limbo   <conn> <msg>   start+write+prepare(+msg), exit unresolved
 *   fb2pc commit  <conn>         start+write+prepare+commit
 *   fb2pc resolve <conn> <id> c|r   reconnect the limbo id, commit/rollback
 *   fb2pc info    <conn>         isc_database_info isc_info_limbo dump
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <ibase.h>

static void die(const char *what, ISC_STATUS *st) {
    char buf[512];
    const ISC_STATUS *p = st;
    fprintf(stderr, "FAIL %s:\n", what);
    while (fb_interpret(buf, sizeof buf, &p)) fprintf(stderr, "  %s\n", buf);
    exit(2);
}

int main(int argc, char **argv) {
    ISC_STATUS st[20];
    isc_db_handle db = 0;
    isc_tr_handle tr = 0;
    if (argc < 3) { fprintf(stderr, "usage: see header\n"); return 2; }
    const char *mode = argv[1], *conn = argv[2];

    char dpb[256]; short dl = 0;
    dpb[dl++] = isc_dpb_version1;
    const char *user = getenv("ISC_USER") ? getenv("ISC_USER") : "SYSDBA";
    const char *pass = getenv("ISC_PASSWORD") ? getenv("ISC_PASSWORD") : "masterkey";
    dpb[dl++] = isc_dpb_user_name; dpb[dl++] = (char)strlen(user);
    memcpy(dpb + dl, user, strlen(user)); dl += (short)strlen(user);
    dpb[dl++] = isc_dpb_password; dpb[dl++] = (char)strlen(pass);
    memcpy(dpb + dl, pass, strlen(pass)); dl += (short)strlen(pass);

    if (isc_attach_database(st, 0, conn, &db, dl, dpb)) die("attach", st);

    if (!strcmp(mode, "info")) {
        char items[] = { isc_info_limbo, isc_info_end };
        char res[1024];
        if (isc_database_info(st, &db, sizeof items, items, sizeof res, res))
            die("info", st);
        /* dump raw clusters: tag, u16 len, VAX int per limbo id */
        for (int i = 0; i < (int)sizeof res && res[i] != isc_info_end;) {
            int tag = res[i++] & 0xff;
            int len = (res[i] & 0xff) | ((res[i + 1] & 0xff) << 8); i += 2;
            long v = isc_vax_integer(res + i, (short)len);
            printf("item %d len %d value %ld\n", tag, len, v);
            i += len;
        }
        isc_detach_database(st, &db);
        return 0;
    }

    if (!strcmp(mode, "resolve")) {
        if (argc < 5) { fprintf(stderr, "resolve needs <id> c|r\n"); return 2; }
        long id = atol(argv[3]);
        /* the byte order gfix itself uses (tdr.cpp): VAX/LE long */
        char idbuf[4];
        idbuf[0] = (char)(id & 0xff); idbuf[1] = (char)((id >> 8) & 0xff);
        idbuf[2] = (char)((id >> 16) & 0xff); idbuf[3] = (char)((id >> 24) & 0xff);
        if (isc_reconnect_transaction(st, &db, &tr, sizeof idbuf, idbuf))
            die("reconnect", st);
        if (argv[4][0] == 'c') {
            if (isc_commit_transaction(st, &tr)) die("commit-after-reconnect", st);
            printf("resolved %ld: committed\n", id);
        } else {
            if (isc_rollback_transaction(st, &tr)) die("rollback-after-reconnect", st);
            printf("resolved %ld: rolled back\n", id);
        }
        isc_detach_database(st, &db);
        return 0;
    }

    /* limbo | commit | noop | stmt: start, [write], prepare, [more] */
    if (isc_start_transaction(st, &tr, 1, &db, 0, NULL)) die("start", st);

    long tid = 0;
    {
        char items[] = { isc_info_tra_id, isc_info_end };
        char res[64];
        if (isc_transaction_info(st, &tr, sizeof items, items, sizeof res, res))
            die("tra_info", st);
        if ((res[0] & 0xff) == isc_info_tra_id) {
            int len = (res[1] & 0xff) | ((res[2] & 0xff) << 8);
            tid = isc_vax_integer(res + 3, (short)len);
        }
        printf("transaction id %ld\n", tid);
    }

    /* FB2PC_INSERT overrides the write - the index-law probes put the
     * limbo row into an INDEXED table */
    const char *ins = getenv("FB2PC_INSERT")
        ? getenv("FB2PC_INSERT")
        : "INSERT INTO T2PC (ID, V) VALUES (1, 'p')";
    if (strcmp(mode, "noop") != 0 &&
        isc_dsql_execute_immediate(st, &db, &tr, 0, ins, 3, NULL))
        die("insert", st);

    if (argc >= 4 && strcmp(mode, "limbo") == 0) {
        /* prepare WITH a message - gfix -list prints it back */
        const char *msg = argv[3];
        if (isc_prepare_transaction2(st, &tr, (unsigned short)strlen(msg),
                (const ISC_UCHAR *)msg))
            die("prepare2", st);
        printf("prepared (msg) id %ld\n", tid);
    } else {
        if (isc_prepare_transaction(st, &tr)) die("prepare", st);
        printf("prepared id %ld\n", tid);
    }

    if (!strcmp(mode, "stmt")) {
        /* a statement under a PREPARED transaction - what does the
         * engine say? */
        if (isc_dsql_execute_immediate(st, &db, &tr, 0,
                "INSERT INTO T2PC (ID, V) VALUES (-1, 'x')", 3, NULL)) {
            char buf[512]; const ISC_STATUS *p = st;
            printf("stmt-after-prepare refused:\n");
            while (fb_interpret(buf, sizeof buf, &p)) printf("  %s\n", buf);
            return 0;
        }
        printf("stmt-after-prepare RAN\n");
        return 0;
    }
    if (!strcmp(mode, "rollb")) {
        if (isc_rollback_transaction(st, &tr)) die("rollback-after-prepare", st);
        printf("rolled back after prepare\n");
        isc_detach_database(st, &db);
        return 0;
    }
    if (!strcmp(mode, "noop")) {
        printf("noop prepared, exiting unresolved\n");
        return 0;
    }
    if (!strcmp(mode, "commit")) {
        if (isc_commit_transaction(st, &tr)) die("commit-after-prepare", st);
        printf("committed after prepare\n");
        isc_detach_database(st, &db);
        return 0;
    }

    /* limbo: exit WITHOUT resolving - the handle dies with the process,
     * the prepared transaction must stay in limbo */
    printf("exiting unresolved\n");
    return 0;
}
