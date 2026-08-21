/* The blob info / seek differential: writes a segmented and a stream
 * blob through the blob ops, stores them with a parameterised INSERT,
 * reads them back - isc_blob_info on the write and the read handle,
 * isc_get_segment with small buffers (partial segments, isc_segment),
 * isc_seek_blob in all three modes and past both ends, a seek on a
 * segmented blob (isc_bad_segstr_type). Every number printed is
 * compared against the engine's.
 *
 *   blobinfo <connection-string> [inline]   (inline = keep the client's
 *   default inline-blob size, so small blobs ride with the row)
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
static long code(void) { return (long)st[1]; }

static void info(const char *tag, isc_blob_handle bh) {
    char items[] = { isc_info_blob_num_segments, isc_info_blob_max_segment,
                     isc_info_blob_total_length, isc_info_blob_type, isc_info_end };
    char buf[64];
    if (isc_blob_info(st, &bh, sizeof items, items, sizeof buf, buf)) die("blob_info");
    printf("info %s:", tag);
    for (char *p = buf; *p != isc_info_end && p < buf + sizeof buf;) {
        int item = *p++;
        int len = isc_vax_integer(p, 2); p += 2;
        long v = isc_vax_integer(p, len); p += len;
        printf(" %d=%ld", item, v);
    }
    printf("\n");
}

static void put(isc_blob_handle *bh, const char *data, int len) {
    if (isc_put_segment(st, bh, (unsigned short)len, data)) die("put_segment");
}

static void read_all(const char *tag, isc_blob_handle bh, int buflen) {
    char *buf = malloc(buflen + 1);
    unsigned short got;
    int n = 0;
    for (;;) {
        ISC_STATUS rc = isc_get_segment(st, &bh, &got, (unsigned short)buflen, buf);
        if (rc == 0 || rc == isc_segment) {
            buf[got] = 0;
            printf("%s seg %d: %s len=%u head=%.6s\n", tag, n++, rc == isc_segment ? "PART" : "OK", got, buf);
        } else if (rc == isc_segstr_eof) {
            printf("%s eof after %d\n", tag, n);
            break;
        } else die("get_segment");
        if (n > 50) break;
    }
    free(buf);
}

static void seek(const char *tag, isc_blob_handle bh, int mode, long off) {
    ISC_LONG result = -1;
    if (isc_seek_blob(st, &bh, (short)mode, (ISC_LONG)off, &result)) {
        printf("%s seek(%d,%ld): error %ld\n", tag, mode, off, code());
        return;
    }
    printf("%s seek(%d,%ld) -> %ld\n", tag, mode, off, (long)result);
}

int main(int argc, char **argv) {
    if (argc < 2) { fprintf(stderr, "usage: blobinfo <conn>\n"); return 2; }
    setvbuf(stdout, NULL, _IOLBF, 0);
    char dpb[64]; int dl = 0;
    dpb[dl++] = isc_dpb_version1;
    dpb[dl++] = isc_dpb_user_name; dpb[dl++] = 6; memcpy(dpb + dl, "SYSDBA", 6); dl += 6;
    dpb[dl++] = isc_dpb_password; dpb[dl++] = 9; memcpy(dpb + dl, "masterkey", 9); dl += 9;
    /* no INLINE blobs (FB6 ships a small blob with the row and then
     * answers info / seek / get_segment from the client's cache): the
     * ops must reach the server on both sides for this to measure them */
    if (argc < 3 || strcmp(argv[2], "inline") != 0) {
        dpb[dl++] = isc_dpb_max_inline_blob_size; dpb[dl++] = 4; dpb[dl++] = 0; dpb[dl++] = 0; dpb[dl++] = 0; dpb[dl++] = 0;
    }
    if (isc_attach_database(st, 0, argv[1], &db, (short)dl, dpb)) die("attach");
    if (isc_start_transaction(st, &tr, 1, &db, 0, NULL)) die("start");

    /* a segmented blob: 5 + 4 + 300 + 5 bytes in four puts */
    isc_blob_handle wb = 0; ISC_QUAD seg_id, str_id;
    if (isc_create_blob2(st, &db, &tr, &wb, &seg_id, 0, NULL)) die("create seg");
    char big[300]; memset(big, 'x', sizeof big);
    put(&wb, "alpha", 5); put(&wb, "beta", 4); put(&wb, big, 300); put(&wb, "omega", 5);
    info("seg-write-handle", wb);
    if (isc_close_blob(st, &wb)) die("close seg");

    /* a stream blob: 50 bytes in five puts */
    char bpb[] = { isc_bpb_version1, isc_bpb_type, 1, isc_bpb_type_stream };
    wb = 0;
    if (isc_create_blob2(st, &db, &tr, &wb, &str_id, sizeof bpb, bpb)) die("create str");
    for (int i = 0; i < 5; i++) put(&wb, "0123456789", 10);
    info("str-write-handle", wb);
    if (isc_close_blob(st, &wb)) die("close str");

    /* INSERT INTO B VALUES (1, ?, ?) */
    XSQLDA *in = (XSQLDA *)calloc(1, XSQLDA_LENGTH(2));
    in->version = SQLDA_VERSION1; in->sqln = 2; in->sqld = 2;
    short ind0 = 0, ind1 = 0;
    in->sqlvar[0].sqltype = SQL_BLOB; in->sqlvar[0].sqldata = (char *)&seg_id; in->sqlvar[0].sqllen = 8; in->sqlvar[0].sqlind = &ind0;
    in->sqlvar[1].sqltype = SQL_BLOB; in->sqlvar[1].sqldata = (char *)&str_id; in->sqlvar[1].sqllen = 8; in->sqlvar[1].sqlind = &ind1;
    isc_stmt_handle sth = 0;
    if (isc_dsql_allocate_statement(st, &db, &sth)) die("alloc");
    int inline_mode = (argc >= 3 && strcmp(argv[2], "inline") == 0);
    char ins[96], sel[96];
    snprintf(ins, sizeof ins, "INSERT INTO B (ID, SEG, STR) VALUES (%d, ?, ?)", inline_mode ? 2 : 1);
    snprintf(sel, sizeof sel, "SELECT SEG, STR FROM B WHERE ID = %d", inline_mode ? 2 : 1);
    if (isc_dsql_prepare(st, &tr, &sth, 0, ins, 3, NULL)) die("prepare insert");
    if (isc_dsql_execute(st, &tr, &sth, 1, in)) die("execute insert");
    if (isc_dsql_free_statement(st, &sth, DSQL_drop)) die("free");
    if (isc_commit_transaction(st, &tr)) die("commit");
    printf("stored\n");

    /* read back */
    if (isc_start_transaction(st, &tr, 1, &db, 0, NULL)) die("start2");
    XSQLDA *out = (XSQLDA *)calloc(1, XSQLDA_LENGTH(2));
    out->version = SQLDA_VERSION1; out->sqln = 2;
    ISC_QUAD rseg, rstr; short i0, i1;
    sth = 0;
    if (isc_dsql_allocate_statement(st, &db, &sth)) die("alloc2");
    if (isc_dsql_prepare(st, &tr, &sth, 0, sel, 3, out)) die("prepare select");
    out->sqlvar[0].sqldata = (char *)&rseg; out->sqlvar[0].sqlind = &i0; out->sqlvar[0].sqltype = SQL_BLOB + 1;
    out->sqlvar[1].sqldata = (char *)&rstr; out->sqlvar[1].sqlind = &i1; out->sqlvar[1].sqltype = SQL_BLOB + 1;
    if (isc_dsql_execute(st, &tr, &sth, 1, NULL)) die("execute select");
    if (isc_dsql_fetch(st, &sth, 1, out)) die("fetch");

    isc_blob_handle rb = 0;
    if (isc_open_blob2(st, &db, &tr, &rb, &rseg, 0, NULL)) die("open seg");
    info("seg", rb);
    seek("seg", rb, 0, 3);
    read_all("seg/256", rb, 256);
    if (isc_close_blob(st, &rb)) die("close");
    rb = 0;
    if (isc_open_blob2(st, &db, &tr, &rb, &rseg, 0, NULL)) die("open seg 2");
    read_all("seg/100", rb, 100);
    if (isc_close_blob(st, &rb)) die("close");

    rb = 0;
    if (isc_open_blob2(st, &db, &tr, &rb, &rstr, 0, NULL)) die("open str");
    info("str", rb);
    seek("str", rb, 0, 10);
    read_all("str/7", rb, 7);
    seek("str", rb, 0, 10);
    seek("str", rb, 1, -3);
    seek("str", rb, 1, 5);
    read_all("str/100", rb, 100);
    seek("str", rb, 2, -4);
    read_all("str/100", rb, 100);
    seek("str", rb, 0, 1000);
    read_all("str/past", rb, 100);
    seek("str", rb, 0, -5);
    read_all("str/neg", rb, 20);
    seek("str", rb, 2, 0);
    read_all("str/end", rb, 20);
    if (isc_close_blob(st, &rb)) die("close");

    /* the empty and the NULL blob */
    if (isc_dsql_free_statement(st, &sth, DSQL_drop)) die("free2");
    if (isc_commit_transaction(st, &tr)) die("commit2");
    if (isc_detach_database(st, &db)) die("detach");
    printf("done\n");
    return 0;
}
