/* The LIST-aggregate blob differential client: runs a query whose single
 * output column is a blob (a LIST result), opens the blob over the wire
 * (inline blobs disabled through the DPB so op_open_blob2 / op_info_blob
 * / op_get_segment answer), and prints the describe, the isc_blob_info
 * numbers and every segment - so the gate compares the engine's answers
 * line for line, id-free. A NULL result prints "row: NULL".
 *
 *   listblob <connection-string> <sql>
 */
#include <ibase.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static ISC_STATUS_ARRAY st;
static isc_db_handle db = 0;
static isc_tr_handle tr = 0;

static void die(const char *what) {
    char msg[512];
    const ISC_STATUS *p = st;
    printf("FAIL %s:", what);
    while (fb_interpret(msg, sizeof msg, &p)) printf(" [%s]", msg);
    printf("\n");
    exit(1);
}

int main(int argc, char **argv) {
    if (argc < 3) { printf("usage: listblob <conn> <sql>\n"); return 1; }
    char dpb[64]; short dl = 0;
    dpb[dl++] = isc_dpb_version1;
    dpb[dl++] = isc_dpb_user_name; dpb[dl++] = 6; memcpy(dpb + dl, "SYSDBA", 6); dl += 6;
    dpb[dl++] = isc_dpb_password; dpb[dl++] = 9; memcpy(dpb + dl, "masterkey", 9); dl += 9;
    /* disable inline blobs so info/seek/get_segment go over the wire */
    dpb[dl++] = isc_dpb_max_inline_blob_size; dpb[dl++] = 4;
    memset(dpb + dl, 0, 4); dl += 4;
    if (isc_attach_database(st, 0, argv[1], &db, dl, dpb)) die("attach");
    if (isc_start_transaction(st, &tr, 1, &db, 0, NULL)) die("start");

    isc_stmt_handle stmt = 0;
    if (isc_dsql_allocate_statement(st, &db, &stmt)) die("alloc");
    XSQLDA *out = (XSQLDA *)malloc(XSQLDA_LENGTH(4));
    out->version = SQLDA_VERSION1; out->sqln = 4;
    if (isc_dsql_prepare(st, &tr, &stmt, 0, argv[2], 3, out)) die("prepare");
    printf("cols %d: type %d sub %d scale %d len %d\n", out->sqld,
           out->sqlvar[0].sqltype, out->sqlvar[0].sqlsubtype,
           out->sqlvar[0].sqlscale, out->sqlvar[0].sqllen);
    ISC_QUAD bid; short ind = 0;
    out->sqlvar[0].sqldata = (char *)&bid;
    out->sqlvar[0].sqlind = &ind;
    out->sqlvar[0].sqltype = SQL_BLOB + 1;
    if (isc_dsql_execute(st, &tr, &stmt, 3, NULL)) die("exec");
    long rc;
    while ((rc = isc_dsql_fetch(st, &stmt, 3, out)) == 0) {
        if (ind == -1) { printf("row: NULL\n"); continue; }
        isc_blob_handle bh = 0;
        if (isc_open_blob2(st, &db, &tr, &bh, &bid, 0, NULL)) die("open");
        char items[] = { isc_info_blob_num_segments, isc_info_blob_max_segment,
                         isc_info_blob_total_length, isc_info_blob_type, isc_info_end };
        char buf[64];
        if (isc_blob_info(st, &bh, sizeof items, items, sizeof buf, buf)) die("info");
        printf("info:");
        for (char *p = buf; *p != isc_info_end && p < buf + sizeof buf;) {
            int item = *p++; int len = isc_vax_integer(p, 2); p += 2;
            long v = isc_vax_integer(p, len); p += len;
            printf(" %d=%ld", item, v);
        }
        printf("\n");
        char seg[64]; unsigned short got = 0; ISC_STATUS s2;
        printf("segs:");
        for (;;) {
            s2 = isc_get_segment(st, &bh, &got, sizeof seg, seg);
            if (s2 == 0 || s2 == isc_segment) { printf(" [%d:%.*s]", got, got, seg); }
            else break;
        }
        printf(" end=%ld\n", (long)s2 == (long)isc_segstr_eof ? 0 : (long)s2);
        isc_close_blob(st, &bh);
    }
    if (rc != 100L) die("fetch");
    isc_dsql_free_statement(st, &stmt, DSQL_drop);
    isc_commit_transaction(st, &tr);
    isc_detach_database(st, &db);
    return 0;
}
