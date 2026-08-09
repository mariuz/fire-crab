/* fbnw2 <conn> <iso>  iso = conc | read : A holds uncommitted update on
 * row1; B (iso, NO WAIT) updates row1 -> what vector? */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <ibase.h>
static void warn(const char*w,ISC_STATUS*st){char b[512];const ISC_STATUS*p=st;
 printf("%s: ",w);while(fb_interpret(b,sizeof b,&p))printf("%s | ",b);printf("\n");}
int main(int c,char**v){ISC_STATUS st[20];isc_db_handle A=0,B=0;isc_tr_handle ta=0,tb=0;
 int rc=strcmp(v[2],"read")==0;
 char d[128];short dl=0;d[dl++]=isc_dpb_version1;
 d[dl++]=isc_dpb_user_name;d[dl++]=6;memcpy(d+dl,"SYSDBA",6);dl+=6;
 d[dl++]=isc_dpb_password;d[dl++]=9;memcpy(d+dl,"masterkey",9);dl+=9;
 if(isc_attach_database(st,0,v[1],&A,dl,d)){warn("aA",st);return 2;}
 if(isc_attach_database(st,0,v[1],&B,dl,d)){warn("aB",st);return 2;}
 if(isc_start_transaction(st,&ta,1,&A,0,NULL)){warn("sA",st);return 2;}
 if(isc_dsql_execute_immediate(st,&A,&ta,0,"UPDATE T SET V=100 WHERE ID=1",3,NULL)){warn("Aupd",st);return 2;}
 char t[8];short tl=0;t[tl++]=isc_tpb_version3;
 if(rc){t[tl++]=isc_tpb_read_committed;t[tl++]=isc_tpb_rec_version;}else t[tl++]=isc_tpb_concurrency;
 t[tl++]=isc_tpb_write;t[tl++]=isc_tpb_nowait;
 if(isc_start_transaction(st,&tb,1,&B,tl,t)){warn("sB",st);return 2;}
 if(isc_dsql_execute_immediate(st,&B,&tb,0,"UPDATE T SET V=200 WHERE ID=1",3,NULL))warn("B nowait",st);
 else printf("B: SUCCEEDED\n");
 isc_rollback_transaction(st,&tb);isc_rollback_transaction(st,&ta);
 isc_detach_database(st,&A);isc_detach_database(st,&B);return 0;}
