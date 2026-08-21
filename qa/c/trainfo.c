/* op_info_transaction: ask a live transaction about itself - every
   isc_info_tra_* item, under several TPBs - and print the raw answer. */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <ibase.h>
static ISC_STATUS st[20];
static const char *errtext(void) { static char b[512]; const ISC_STATUS *p = st; fb_interpret(b, sizeof b, &p); return b; }
static void die(const char *w) { printf("FAIL %s: [%s]\n", w, errtext()); exit(1); }
static void ask(isc_db_handle db, const char *tag, const char *tpb, int tpblen) {
    isc_tr_handle tr = 0;
    if (isc_start_transaction(st, &tr, 1, &db, (unsigned short)tpblen, tpb)) { printf("%s: start error %s\n", tag, errtext()); return; }
    char items[] = { isc_info_tra_id, isc_info_tra_oldest_interesting, isc_info_tra_oldest_snapshot, isc_info_tra_oldest_active,
                     isc_info_tra_isolation, isc_info_tra_access, isc_info_tra_lock_timeout, fb_info_tra_dbpath, fb_info_tra_snapshot_number, isc_info_end };
    unsigned char buf[512]; memset(buf, 0, sizeof buf);
    if (isc_transaction_info(st, &tr, sizeof items, items, sizeof buf, (char *)buf)) { printf("%s: info error %s\n", tag, errtext()); isc_rollback_transaction(st, &tr); return; }
    /* walk the clumps; numbers print as values (ids move between runs, so the ordering is what is compared) */
    printf("%s:", tag);
    unsigned char *p = buf;
    while (*p != isc_info_end) {
        int item = *p++; int len = isc_vax_integer((char *)p, 2); p += 2;
        switch (item) {
        case isc_info_tra_id: printf(" id(len %d)", len); break;
        case isc_info_tra_oldest_interesting: printf(" oit(len %d)", len); break;
        case isc_info_tra_oldest_snapshot: printf(" ost(len %d)", len); break;
        case isc_info_tra_oldest_active: printf(" oat(len %d)", len); break;
        case isc_info_tra_isolation: printf(" isolation(len %d)=%d", len, p[0]); if (len > 1) printf(",%d", p[1]); break;
        case isc_info_tra_access: printf(" access=%d", p[0]); break;
        case isc_info_tra_lock_timeout: printf(" lock_timeout=%ld", (long)isc_vax_integer((char *)p, len)); break;
        case fb_info_tra_dbpath: printf(" dbpath='%.*s'", len, p); break;
        case fb_info_tra_snapshot_number: printf(" snapshot(len %d)", len); break;
        default: printf(" item%d(len %d)", item, len);
        }
        p += len;
    }
    printf("\n");
    /* the relations between the counters hold on both: id >= oat >= ost >= oit, snapshot > 0 unless read committed */
    {   long id = 0, oit = 0, ost = 0, oat = 0; long long snap = -1; int rc = 0;
        unsigned char *q = buf;
        while (*q != isc_info_end) { int item = *q++; int len = isc_vax_integer((char *)q, 2); q += 2;
            long v = isc_vax_integer((char *)q, len > 4 ? 4 : len);
            if (item == isc_info_tra_id) id = v; if (item == isc_info_tra_oldest_interesting) oit = v; if (item == isc_info_tra_oldest_snapshot) ost = v; if (item == isc_info_tra_oldest_active) oat = v;
            if (item == fb_info_tra_snapshot_number) snap = isc_portable_integer(q, len);
            if (item == isc_info_tra_isolation && q[0] == isc_info_tra_read_committed) rc = 1;
            q += len; }
        printf("%s laws: id>=oat %d, oat>=ost %d, ost>=oit %d, oit>0 %d, snapshot %s\n", tag, id >= oat, oat >= ost, ost >= oit, oit > 0, rc ? (snap == 0 ? "zero (read committed)" : "nonzero (read committed!)") : (snap > 0 ? "positive" : "ZERO"));
    }
    {   char rev[] = { fb_info_tra_snapshot_number, isc_info_tra_access, isc_info_tra_id, isc_info_tra_isolation, isc_info_tra_id, 77, isc_info_end };
        unsigned char b2[256]; memset(b2, 0, sizeof b2);
        if (isc_transaction_info(st, &tr, sizeof rev, rev, sizeof b2, (char *)b2)) printf("%s reversed: info error %s\n", tag, errtext());
        else { printf("%s reversed:", tag); unsigned char *p = b2; while (*p != isc_info_end) { int item = *p++; int len = isc_vax_integer((char *)p, 2); p += 2; printf(" %d(len %d)", item, len); p += len; } printf("\n"); }
        /* a buffer too small for the answer: isc_info_truncated */
        unsigned char b3[12]; memset(b3, 0, sizeof b3);
        if (isc_transaction_info(st, &tr, sizeof items, items, sizeof b3, (char *)b3)) printf("%s small: info error %s\n", tag, errtext());
        else { printf("%s small:", tag); unsigned char *p = b3; int k = 0; while (k < 12 && *p != isc_info_end && *p != isc_info_truncated) { int item = *p++; int len = isc_vax_integer((char *)p, 2); p += 2 + len; k = p - b3; printf(" %d", item); } printf(" end=%d\n", *p); }
    }
    if (isc_rollback_transaction(st, &tr)) die("rollback");
}
int main(int argc, char **argv) {
    if (argc < 2) { fprintf(stderr, "usage: trainfo <conn>\n"); return 2; }
    setvbuf(stdout, NULL, _IOLBF, 0);
    isc_db_handle db = 0;
    char dpb[64]; int n = 0; dpb[n++] = isc_dpb_version1;
    dpb[n++] = isc_dpb_user_name; dpb[n++] = 6; memcpy(dpb + n, "SYSDBA", 6); n += 6;
    dpb[n++] = isc_dpb_password; dpb[n++] = 9; memcpy(dpb + n, "masterkey", 9); n += 9;
    if (isc_attach_database(st, 0, argv[1], &db, n, dpb)) die("attach");
    { char t[] = { isc_tpb_version3, isc_tpb_write, isc_tpb_concurrency, isc_tpb_wait }; ask(db, "concurrency wait", t, sizeof t); }
    { char t[] = { isc_tpb_version3, isc_tpb_read, isc_tpb_concurrency, isc_tpb_nowait }; ask(db, "read-only concurrency nowait", t, sizeof t); }
    { char t[] = { isc_tpb_version3, isc_tpb_write, isc_tpb_read_committed, isc_tpb_rec_version, isc_tpb_wait }; ask(db, "read committed rec_version", t, sizeof t); }
    { char t[] = { isc_tpb_version3, isc_tpb_write, isc_tpb_read_committed, isc_tpb_no_rec_version, isc_tpb_nowait }; ask(db, "read committed no_rec_version", t, sizeof t); }
    { char t[] = { isc_tpb_version3, isc_tpb_write, isc_tpb_read_committed, isc_tpb_read_consistency, isc_tpb_wait }; ask(db, "read committed read_consistency", t, sizeof t); }
    { char t[] = { isc_tpb_version3, isc_tpb_write, isc_tpb_consistency, isc_tpb_wait }; ask(db, "consistency", t, sizeof t); }
    { char t[] = { isc_tpb_version3, isc_tpb_write, isc_tpb_concurrency, isc_tpb_wait, isc_tpb_lock_timeout, 4, 7, 0, 0, 0 }; ask(db, "wait lock_timeout 7", t, sizeof t); }
    { char t[] = { isc_tpb_version3, isc_tpb_write, isc_tpb_concurrency, isc_tpb_wait, isc_tpb_at_snapshot_number, 8, 1, 0, 0, 0, 0, 0, 0, 0 }; ask(db, "at snapshot 1", t, sizeof t); }
    /* a transaction that did a write: its id is its own, the snapshot still the start's */
    {   isc_tr_handle tr = 0; if (isc_start_transaction(st, &tr, 1, &db, 0, NULL)) die("start w");
        if (isc_dsql_execute_immediate(st, &db, &tr, 0, "CREATE TABLE TI (X INTEGER)", 3, NULL)) die("ddl");
        if (isc_commit_transaction(st, &tr)) die("commit w"); }
    { char t[] = { isc_tpb_version3, isc_tpb_write, isc_tpb_concurrency, isc_tpb_wait }; ask(db, "after a commit", t, sizeof t); }
    if (isc_detach_database(st, &db)) die("detach");
    printf("done\n"); return 0;
}
