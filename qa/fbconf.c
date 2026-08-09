/* fbconf <conn> <op> [read]
 *   op  = update | delete | del-by-b
 *   iso = concurrency (default) | read  (read-committed)
 * A opens a transaction (NO WAIT); B modifies+commits row 1; A then
 * does <op> on row 1. Under SNAPSHOT A cannot write over B's commit
 * (update conflict); under READ COMMITTED it can. */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <ibase.h>
static void warn(const char *w, ISC_STATUS *st) {
    char b[512]; const ISC_STATUS *p = st;
    printf("%s: ", w);
    while (fb_interpret(b, sizeof b, &p)) printf("%s | ", b);
    printf("\n");
}
int main(int argc, char **argv) {
    ISC_STATUS st[20]; isc_db_handle A = 0, B = 0; isc_tr_handle ta = 0, tb = 0;
    const char *conn = argv[1];
    const char *op = argc > 2 ? argv[2] : "update";
    int rc_iso = argc > 3 && strcmp(argv[3], "read") == 0;
    char dpb[128]; short dl = 0; dpb[dl++] = isc_dpb_version1;
    dpb[dl++] = isc_dpb_user_name; dpb[dl++] = 6; memcpy(dpb + dl, "SYSDBA", 6); dl += 6;
    dpb[dl++] = isc_dpb_password; dpb[dl++] = 9; memcpy(dpb + dl, "masterkey", 9); dl += 9;
    if (isc_attach_database(st, 0, conn, &A, dl, dpb)) { warn("attachA", st); return 2; }
    if (isc_attach_database(st, 0, conn, &B, dl, dpb)) { warn("attachB", st); return 2; }
    char tp[8]; short tl = 0; tp[tl++] = isc_tpb_version3;
    if (rc_iso) { tp[tl++] = isc_tpb_read_committed; tp[tl++] = isc_tpb_rec_version; }
    else tp[tl++] = isc_tpb_concurrency;
    tp[tl++] = isc_tpb_write; tp[tl++] = isc_tpb_nowait;
    if (isc_start_transaction(st, &ta, 1, &A, tl, tp)) { warn("startA", st); return 2; }
    isc_dsql_execute_immediate(st, &A, &ta, 0, "UPDATE T SET V=V WHERE 1=0", 3, NULL);
    if (isc_start_transaction(st, &tb, 1, &B, 0, NULL)) { warn("startB", st); return 2; }
    const char *bs = strcmp(op, "del-by-b") == 0 ? "DELETE FROM T WHERE ID=1"
                                                 : "UPDATE T SET V=100 WHERE ID=1";
    if (isc_dsql_execute_immediate(st, &B, &tb, 0, bs, 3, NULL)) { warn("B", st); return 2; }
    if (isc_commit_transaction(st, &tb)) { warn("commitB", st); return 2; }
    const char *as = strcmp(op, "delete") == 0 ? "DELETE FROM T WHERE ID=1"
                                               : "UPDATE T SET V=200 WHERE ID=1";
    if (isc_dsql_execute_immediate(st, &A, &ta, 0, as, 3, NULL)) warn("A after B", st);
    else printf("A after B: SUCCEEDED\n");
    isc_rollback_transaction(st, &ta);
    isc_detach_database(st, &A); isc_detach_database(st, &B);
    return 0;
}
