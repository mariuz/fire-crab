/* ddlphase <conn> <sql>... : for each statement, PREPARE then EXECUTE then COMMIT in its own
 * transaction, printing which phase raised (PREPARE ERR / EXECUTE ERR / COMMIT ERR) and
 * the interpreted status vector - so a gate can pin the PHASE of a DDL refusal, which
 * isql (prepare, execute and autoddl commit in one step) cannot tell apart. */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <ibase.h>
static void err(const char*ph, ISC_STATUS*st){const ISC_STATUS*p=st;char b[512];printf("%s ERR:",ph);
 while(fb_interpret(b,sizeof b,&p)){printf(" |%s",b);} printf("\n");}
int main(int c,char**v){ISC_STATUS st[40];isc_db_handle db=0;isc_tr_handle tr=0;
 char d[128];short dl=0;d[dl++]=isc_dpb_version1;d[dl++]=isc_dpb_user_name;d[dl++]=6;memcpy(d+dl,"SYSDBA",6);dl+=6;d[dl++]=isc_dpb_password;d[dl++]=9;memcpy(d+dl,"masterkey",9);dl+=9;
 if(isc_attach_database(st,0,v[1],&db,dl,d)){err("ATTACH",st);return 2;}
 for(int i=2;i<c;i++){
  tr=0; isc_start_transaction(st,&tr,1,&db,0,NULL);
  isc_stmt_handle s=0; isc_dsql_allocate_statement(st,&db,&s);
  if(isc_dsql_prepare(st,&tr,&s,0,v[i],3,NULL)){err("PREPARE",st);isc_rollback_transaction(st,&tr);continue;}
  printf("PREPARED\n");
  if(isc_dsql_execute(st,&tr,&s,3,NULL)){err("EXECUTE",st);isc_rollback_transaction(st,&tr);continue;}
  printf("EXECUTED\n");
  isc_dsql_free_statement(st,&s,DSQL_drop);
  if(isc_commit_transaction(st,&tr)){err("COMMIT",st);}
  else printf("COMMITTED\n");
 }
 isc_detach_database(st,&db); return 0;}
