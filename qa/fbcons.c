/* fbcons <conn> <Atpb...> : A starts with given TPB and READS T (COUNT).
 * Then B (concurrency, NOWAIT) tries INSERT INTO T -> what happens?
 * Then B (concurrency, NOWAIT) tries INSERT INTO U (untouched) -> ? */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <ibase.h>
static void warn(const char*w,ISC_STATUS*st){char b[512];const ISC_STATUS*p=st;printf("%s: ",w);while(fb_interpret(b,sizeof b,&p))printf("%s | ",b);printf("\n");}
static long cnt(isc_db_handle*db,isc_tr_handle*tr,const char*sql){ISC_INT64 n=-1;XSQLDA*o=(XSQLDA*)malloc(XSQLDA_LENGTH(1));o->version=SQLDA_VERSION1;o->sqln=1;isc_stmt_handle s2=0;ISC_STATUS st[20];isc_dsql_allocate_statement(st,db,&s2);if(isc_dsql_prepare(st,tr,&s2,0,sql,3,o)){warn("prep",st);return -9;}o->sqlvar[0].sqldata=(char*)&n;o->sqlvar[0].sqltype=SQL_INT64;o->sqlvar[0].sqllen=8;isc_dsql_execute(st,tr,&s2,3,NULL);isc_dsql_fetch(st,&s2,3,o);isc_dsql_free_statement(st,&s2,DSQL_drop);return (long)n;}
int main(int c,char**v){ISC_STATUS st[20];isc_db_handle A=0,B=0;isc_tr_handle ta=0,tb=0;
 char d[128];short dl=0;d[dl++]=isc_dpb_version1;d[dl++]=isc_dpb_user_name;d[dl++]=6;memcpy(d+dl,"SYSDBA",6);dl+=6;d[dl++]=isc_dpb_password;d[dl++]=9;memcpy(d+dl,"masterkey",9);dl+=9;
 if(isc_attach_database(st,0,v[1],&A,dl,d)){warn("aA",st);return 2;}
 if(isc_attach_database(st,0,v[1],&B,dl,d)){warn("aB",st);return 2;}
 char t[32];short tl=0;for(int i=2;i<c;i++)t[tl++]=(char)atoi(v[i]);
 if(isc_start_transaction(st,&ta,1,&A,tl,t)){warn("sA",st);return 2;}
 printf("A read T: %ld\n", cnt(&A,&ta,"SELECT COUNT(*) FROM T"));
 /* B concurrency NOWAIT */
 char tbp[8];short bl=0;tbp[bl++]=isc_tpb_version3;tbp[bl++]=isc_tpb_concurrency;tbp[bl++]=isc_tpb_write;tbp[bl++]=isc_tpb_nowait;
 if(isc_start_transaction(st,&tb,1,&B,bl,tbp)){warn("sB",st);return 2;}
 if(isc_dsql_execute_immediate(st,&B,&tb,0,"INSERT INTO T (ID) VALUES (99)",3,NULL))warn("B insert T",st); else printf("B insert T: OK\n");
 isc_rollback_transaction(st,&tb);
 isc_start_transaction(st,&tb,1,&B,bl,tbp);
 if(isc_dsql_execute_immediate(st,&B,&tb,0,"INSERT INTO U (ID) VALUES (99)",3,NULL))warn("B insert U",st); else printf("B insert U: OK\n");
 isc_rollback_transaction(st,&tb);
 isc_rollback_transaction(st,&ta);
 isc_detach_database(st,&A);isc_detach_database(st,&B);return 0;}
