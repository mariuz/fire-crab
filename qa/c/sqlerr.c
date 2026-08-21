/* Run each statement given on the command line (after the connection)
   and print its STATUS VECTOR raw - gds codes, strings, numbers - so an
   error's exact shape (which code carries which argument) can be read
   off the engine and mirrored. */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <ibase.h>
static ISC_STATUS st[20];
static void dump(const char *sql) {
    printf("%s\n  ->", sql);
    const ISC_STATUS *p = st;
    if (p[0] != isc_arg_gds || p[1] == 0) { printf(" ok\n"); return; }
    while (*p != isc_arg_end) {
        switch (*p) {
        case isc_arg_gds: printf(" gds %ld", (long)p[1]); p += 2; break;
        case isc_arg_string: printf(" str '%s'", (const char *)p[1]); p += 2; break;
        case isc_arg_cstring: printf(" cstr '%.*s'", (int)p[1], (const char *)p[2]); p += 3; break;
        case isc_arg_number: printf(" num %ld", (long)p[1]); p += 2; break;
        case isc_arg_interpreted: printf(" interp '%s'", (const char *)p[1]); p += 2; break;
        case isc_arg_sql_state: printf(" sqlstate '%s'", (const char *)p[1]); p += 2; break;
        case isc_arg_warning: printf(" warning %ld", (long)p[1]); p += 2; break;
        default: printf(" arg%ld", (long)*p); p += 2;
        }
    }
    printf("\n");
}
int main(int argc, char **argv) {
    if (argc < 3) { fprintf(stderr, "usage: sqlerr <conn> <sql>...\n"); return 2; }
    setvbuf(stdout, NULL, _IOLBF, 0);
    isc_db_handle db = 0; isc_tr_handle tr = 0;
    char dpb[64]; int n = 0; dpb[n++] = isc_dpb_version1;
    dpb[n++] = isc_dpb_user_name; dpb[n++] = 6; memcpy(dpb + n, "SYSDBA", 6); n += 6;
    dpb[n++] = isc_dpb_password; dpb[n++] = 9; memcpy(dpb + n, "masterkey", 9); n += 9;
    if (isc_attach_database(st, 0, argv[1], &db, n, dpb)) { dump("attach"); return 1; }
    for (int i = 2; i < argc; i++) {
        if (!tr && isc_start_transaction(st, &tr, 1, &db, 0, NULL)) { dump("start"); return 1; }
        if (!strcmp(argv[i], "COMMIT")) { isc_commit_transaction(st, &tr); dump(argv[i]); tr = 0; continue; }
        isc_dsql_execute_immediate(st, &db, &tr, 0, argv[i], 3, NULL);
        dump(argv[i]);
    }
    if (tr) isc_commit_transaction(st, &tr);
    isc_detach_database(st, &db);
    return 0;
}
