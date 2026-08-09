/* fbsnap - measure snapshot vs read-committed visibility across two
 * concurrent transactions on one attachment (or two). The whole point:
 * does a transaction see rows another transaction COMMITTED after it
 * began?  SNAPSHOT says no, READ COMMITTED says yes.
 *
 *   fbsnap <conn> <iso>     iso = snap | read
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <ibase.h>

static void die(const char *w, ISC_STATUS *st){char b[512];const ISC_STATUS*p=st;
 fprintf(stderr,"FAIL %s: ",w);while(fb_interpret(b,sizeof b,&p))fprintf(stderr,"%s; ",b);fprintf(stderr,"\n");exit(2);}

static long count(isc_db_handle *db, isc_tr_handle *tr){
 static char q[]="SELECT COUNT(*) FROM T";
 XSQLDA *o=(XSQLDA*)malloc(XSQLDA_LENGTH(1)); o->version=SQLDA_VERSION1; o->sqln=1;
 isc_stmt_handle st=0; ISC_STATUS s[20];
 if(isc_dsql_allocate_statement(s,db,&st))die("alloc",s);
 if(isc_dsql_prepare(s,tr,&st,0,q,3,o))die("prep",s);
 o->sqlvar[0].sqldata=malloc(8); long v=0; o->sqlvar[0].sqldata=(char*)&v;
 short ind=0; o->sqlvar[0].sqlind=&ind;
 if(isc_dsql_execute(s,tr,&st,3,NULL))die("exec",s);
 if(isc_dsql_fetch(s,&st,3,o)==0){} 
 isc_dsql_free_statement(s,&st,DSQL_drop);
 return v;
}

int main(int argc,char**argv){
 ISC_STATUS st[20]; isc_db_handle A=0,B=0; isc_tr_handle ta=0,tb=0;
 const char*conn=argv[1]; const char*iso=argv[2];
 char dpb[128]; short dl=0; dpb[dl++]=isc_dpb_version1;
 const char*u="SYSDBA",*p="masterkey";
 dpb[dl++]=isc_dpb_user_name;dpb[dl++]=6;memcpy(dpb+dl,u,6);dl+=6;
 dpb[dl++]=isc_dpb_password;dpb[dl++]=9;memcpy(dpb+dl,p,9);dl+=9;
 if(isc_attach_database(st,0,conn,&A,dl,dpb))die("attachA",st);
 if(isc_attach_database(st,0,conn,&B,dl,dpb))die("attachB",st);
 /* A's transaction: TPB per iso */
 char tpb[8]; short tl=0; tpb[tl++]=isc_tpb_version3;
 if(!strcmp(iso,"snap")) tpb[tl++]=isc_tpb_concurrency;
 else tpb[tl++]=isc_tpb_read_committed, tpb[tl++]=isc_tpb_rec_version;
 tpb[tl++]=isc_tpb_write; tpb[tl++]=isc_tpb_wait;
 if(isc_start_transaction(st,&ta,1,&A,tl,tpb))die("startA",st);
 printf("A sees at start: %ld\n", count(&A,&ta));
 /* B inserts + commits */
 if(isc_start_transaction(st,&tb,1,&B,0,NULL))die("startB",st);
 if(isc_dsql_execute_immediate(st,&B,&tb,0,"INSERT INTO T VALUES (99)",3,NULL))die("insB",st);
 if(isc_commit_transaction(st,&tb))die("commitB",st);
 printf("A sees after B commits: %ld\n", count(&A,&ta));
 /* A commits, new transaction */
 if(isc_commit_transaction(st,&ta))die("commitA",st);
 if(isc_start_transaction(st,&ta,1,&A,tl,tpb))die("restartA",st);
 printf("A sees in a fresh transaction: %ld\n", count(&A,&ta));
 isc_commit_transaction(st,&ta);
 isc_detach_database(st,&A); isc_detach_database(st,&B);
 return 0;
}
