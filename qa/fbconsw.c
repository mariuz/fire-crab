/* fbconsw <conn> <Atpb...> : A (given TPB) UPDATEs row 1 of T.
 * B (concurrency,nowait) UPDATEs row 2 of T (different row) -> conflict?
 * B (concurrency,nowait) INSERTs into U (untouched) -> ok? */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <ibase.h>
static void warn(const char*w,ISC_STATUS*st){char b[512];const ISC_STATUS*p=st;printf("%s: ",w);while(fb_interpret(b,sizeof b,&p))printf("%s | ",b);printf("\n");}
int main(int c,char**v){ISC_STATUS st[40];isc_db_handle A=0,B=0;isc_tr_handle ta=0,tb=0;
 char d[128];short dl=0;d[dl++]=isc_dpb_version1;d[dl++]=isc_dpb_user_name;d[dl++]=6;memcpy(d+dl,"SYSDBA",6);dl+=6;d[dl++]=isc_dpb_password;d[dl++]=9;memcpy(d+dl,"masterkey",9);dl+=9;
 isc_attach_database(st,0,v[1],&A,dl,d); isc_attach_database(st,0,v[1],&B,dl,d);
 char t[8];short tl=0;for(int i=2;i<c;i++)t[tl++]=(char)atoi(v[i]);
 isc_start_transaction(st,&ta,1,&A,tl,t);
 if(isc_dsql_execute_immediate(st,&A,&ta,0,"UPDATE T SET V=V+1 WHERE ID=1",3,NULL))warn("A upd row1",st); else printf("A upd row1: OK\n");
 char tbp[8];short bl=0;tbp[bl++]=isc_tpb_version3;tbp[bl++]=isc_tpb_concurrency;tbp[bl++]=isc_tpb_write;tbp[bl++]=isc_tpb_nowait;
 isc_start_transaction(st,&tb,1,&B,bl,tbp);
 if(isc_dsql_execute_immediate(st,&B,&tb,0,"UPDATE T SET V=V+1 WHERE ID=2",3,NULL))warn("B upd row2 (diff row)",st); else printf("B upd row2: OK\n");
 isc_rollback_transaction(st,&tb); isc_start_transaction(st,&tb,1,&B,bl,tbp);
 if(isc_dsql_execute_immediate(st,&B,&tb,0,"INSERT INTO U VALUES (9)",3,NULL))warn("B insert U",st); else printf("B insert U: OK\n");
 isc_rollback_transaction(st,&tb); isc_rollback_transaction(st,&ta);
 isc_detach_database(st,&A); isc_detach_database(st,&B); return 0;}
