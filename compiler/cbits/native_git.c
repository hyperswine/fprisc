/* libgit2 mechanisms. No shell, Git hooks, credential helpers or ssh process.
 * Requests are an enum with typed fields, never a command line. */
#include <git2.h>
#include <stdlib.h>
#include <stdio.h>
#include <string.h>
#include <stdarg.h>

typedef struct { char *p; size_t n, cap, limit; int bad; } output;
static void append(output *o, const char *fmt, ...) {
  va_list ap, cp; va_start(ap,fmt); va_copy(cp,ap);
  int n=vsnprintf(NULL,0,fmt,cp); va_end(cp);
  if(n<0 || o->bad){o->bad=1;va_end(ap);return;}
  if((size_t)n>o->limit-o->n){o->bad=1;va_end(ap);return;}
  size_t need=o->n+(size_t)n+1;
  if(need>o->cap){char *p=realloc(o->p,need);if(!p){o->bad=1;va_end(ap);return;}o->p=p;o->cap=need;}
  vsnprintf(o->p+o->n,need-o->n,fmt,ap);va_end(ap);o->n+=(size_t)n;
}
static int patchLine(const git_diff_delta *d,const git_diff_hunk *h,const git_diff_line *l,void *p){
  (void)d;(void)h;output *o=p;
  if(l->origin==' '||l->origin=='+'||l->origin=='-')append(o,"%c",l->origin);
  append(o,"%.*s",(int)l->content_len,l->content);return o->bad ? -1:0;
}
/* Transport failure propagates; defaults verify TLS and SSH host keys.
 * Credentials come only from the native SSH agent API, never helpers. */
typedef struct { output *out; int attempted; } push_context;
static int pushStatus(const char *ref,const char *status,void *p){
  (void)ref;push_context *ctx=p;if(status){append(ctx->out,"%s",status);return -1;}return 0;
}
static int credentials(git_credential **out,const char *url,const char *username,unsigned allowed,void *p){
  (void)url;push_context *ctx=p;
  if(!ctx->attempted && username && (allowed&GIT_CREDENTIAL_SSH_KEY)){
    ctx->attempted=1;return git_credential_ssh_key_from_agent(out,username);
  }
  append(ctx->out,"native Git authentication requires an SSH agent and a username in the remote URL; external credential helpers are disabled");
  return GIT_EAUTH;
}
int fpr_native_git(const char *path,int op,const char *arg,const char *name,const char *email,
                   const char **paths,size_t count,size_t outputLimit,char **result){
  git_repository *r=NULL;git_index *idx=NULL;git_object *obj=NULL;git_tree *tree=NULL;
  git_commit *parent=NULL;git_signature *sig=NULL;git_reference *ref=NULL,*ref2=NULL;
  git_diff *diff=NULL;git_status_list *status=NULL;git_revwalk *walk=NULL;git_remote *remote=NULL;
  output out={.limit=outputLimit};int e=0;git_oid oid;git_strarray ps={(char **)paths,count};
  git_libgit2_init();
#define TRY(x) do{e=(x);if(e<0)goto done;}while(0)
  /* Some libgit2 builds use an external ssh executable. Never select that
   * backend, even when this machine has an ssh binary available. */
  if(op==15){
    const char *ssh=git_libgit2_feature_backend(GIT_FEATURE_SSH);
    if(ssh && strcmp(ssh,"libssh2")){e=-1;append(&out,"native Git push requires a libgit2 build with libssh2, without an executable SSH backend");goto done;}
  }
  if(op==0){
    git_repository_init_options opts=GIT_REPOSITORY_INIT_OPTIONS_INIT;
    opts.flags=GIT_REPOSITORY_INIT_MKPATH;opts.initial_head=*arg?arg:NULL;
    TRY(git_repository_init_ext(&r,path,&opts));goto done;
  }
  TRY(git_repository_open(&r,path));
  switch(op){
  case 1: /* add: arg all/update/paths; empty explicit selection is a no-op */
    TRY(git_repository_index(&idx,r));
    if(!strcmp(arg,"update"))TRY(git_index_update_all(idx,&ps,NULL,NULL));
    else if(strcmp(arg,"paths") || count)TRY(git_index_add_all(idx,&ps,GIT_INDEX_ADD_DEFAULT,NULL,NULL));
    TRY(git_index_write(idx));break;
  case 2: /* unstage */
    e=git_revparse_single(&obj,r,"HEAD");
    if(e==GIT_EUNBORNBRANCH || e==GIT_ENOTFOUND){e=0;}
    else if(e<0)goto done;
    if(!strcmp(arg,"paths") && !count)break;
    if(!count){const char *all="*";ps.strings=(char **)&all;ps.count=1;TRY(git_reset_default(r,obj,&ps));}
    else TRY(git_reset_default(r,obj,&ps));break;
  case 3: /* commit */
    TRY(git_repository_index(&idx,r));if(git_index_has_conflicts(idx)){e=-1;append(&out,"unresolved index conflicts");goto done;}
    TRY(git_index_write_tree(&oid,idx));TRY(git_tree_lookup(&tree,r,&oid));
    e=git_revparse_single(&obj,r,"HEAD");
    if(e==GIT_EUNBORNBRANCH || e==GIT_ENOTFOUND){e=0;}
    else {if(e<0)goto done;TRY(git_commit_lookup(&parent,r,git_object_id(obj)));
      if(git_oid_equal(git_tree_id(tree),git_commit_tree_id(parent))){e=-1;append(&out,"nothing staged to commit");goto done;}}
    if(*name && *email)TRY(git_signature_now(&sig,name,email));else TRY(git_signature_default(&sig,r));
    TRY(git_commit_create(&oid,r,"HEAD",sig,sig,NULL,arg,tree,parent?1:0,(const git_commit **)&parent));break;
  case 4: TRY(git_revparse_single(&obj,r,"HEAD~1"));TRY(git_reset(r,obj,!strcmp(arg,"soft")?GIT_RESET_SOFT:GIT_RESET_MIXED,NULL));break;
  case 5: TRY(git_revparse_single(&obj,r,"HEAD"));TRY(git_commit_lookup(&parent,r,git_object_id(obj)));TRY(git_branch_create(&ref,r,arg,parent,0));break;
  case 6: /* safe delete: refuse unmerged branch */
    TRY(git_branch_lookup(&ref,r,arg,GIT_BRANCH_LOCAL));TRY(git_repository_head(&ref2,r));
    if(!git_oid_equal(git_reference_target(ref),git_reference_target(ref2))){
      e=git_graph_descendant_of(r,git_reference_target(ref2),git_reference_target(ref));
      if(e<=0){e=-1;append(&out,"branch is not merged into HEAD");goto done;}}
    TRY(git_branch_delete(ref));break;
  case 7: { /* safe checkout before moving HEAD */
    TRY(git_branch_lookup(&ref,r,arg,GIT_BRANCH_LOCAL));TRY(git_reference_peel(&obj,ref,GIT_OBJECT_COMMIT));
    git_checkout_options opts=GIT_CHECKOUT_OPTIONS_INIT;opts.checkout_strategy=GIT_CHECKOUT_SAFE;
    TRY(git_checkout_tree(r,obj,&opts));TRY(git_repository_set_head(r,git_reference_name(ref)));break;}
  case 8: TRY(git_revparse_single(&obj,r,"HEAD"));TRY(git_tag_create_lightweight(&oid,r,arg,obj,0));break;
  case 9: TRY(git_tag_delete(r,arg));break;
  case 10: { /* documented native status: branch header + numeric flag/path rows */
    e=git_repository_head(&ref,r);
    if(e==GIT_EUNBORNBRANCH){append(&out,"# branch.oid (initial)\n");e=0;}
    else {if(e<0)goto done;char hex[GIT_OID_HEXSZ+1];git_oid_tostr(hex,sizeof hex,git_reference_target(ref));append(&out,"# branch.oid %s\n# branch.head %s\n",hex,git_reference_shorthand(ref));}
    git_status_options opts=GIT_STATUS_OPTIONS_INIT;opts.flags=GIT_STATUS_OPT_INCLUDE_UNTRACKED|GIT_STATUS_OPT_RECURSE_UNTRACKED_DIRS;
    TRY(git_status_list_new(&status,r,&opts));
    for(size_t i=0;i<git_status_list_entrycount(status);i++){
      const git_status_entry *s=git_status_byindex(status,i);const git_diff_delta *d=s->index_to_workdir?s->index_to_workdir:s->head_to_index;
      /* Quote paths as Git does; tabs/newlines cannot forge a new record. */
      append(&out,"%u\t\"",s->status);const unsigned char *p=(const unsigned char *)d->new_file.path;
      for(;*p;p++){if(*p=='"'||*p=='\\')append(&out,"\\%c",*p);else if(*p<32||*p==127)append(&out,"\\%03o",*p);else append(&out,"%c",*p);}append(&out,"\"\n");
    }break;}
  case 11: TRY(git_diff_index_to_workdir(&diff,r,NULL,NULL));TRY(git_diff_print(diff,GIT_DIFF_FORMAT_PATCH,patchLine,&out));break;
  case 12:
    e=git_revparse_single(&obj,r,"HEAD^{tree}");
    if(e==GIT_EUNBORNBRANCH || e==GIT_ENOTFOUND){e=0;}else if(e<0)goto done;
    TRY(git_diff_tree_to_index(&diff,r,(git_tree *)obj,NULL,NULL));TRY(git_diff_print(diff,GIT_DIFF_FORMAT_PATCH,patchLine,&out));break;
  case 13: { /* requested count validated on FP-RISC side */
    TRY(git_revwalk_new(&walk,r));git_revwalk_sorting(walk,GIT_SORT_TIME|GIT_SORT_TOPOLOGICAL);TRY(git_revwalk_push_head(walk));
    long n=strtol(arg,NULL,10);while(n-->0 && !(e=git_revwalk_next(&oid,walk))){
      git_commit_free(parent);parent=NULL;TRY(git_commit_lookup(&parent,r,&oid));char hex[GIT_OID_HEXSZ+1];git_oid_tostr(hex,sizeof hex,&oid);
      append(&out,"%s\t%s\n",hex,git_commit_summary(parent));
    }if(e==GIT_ITEROVER)e=0;break;}
  case 14: TRY(git_revparse_single(&obj,r,"HEAD"));{char hex[GIT_OID_HEXSZ+1];git_oid_tostr(hex,sizeof hex,git_object_id(obj));append(&out,"%s\n",hex);}break;
  case 15: { /* remote name, explicit local branch; no refspec injection */
    if(count!=1){e=-1;goto done;}
    int valid=0;TRY(git_branch_name_is_valid(&valid,paths[0]));if(!valid){e=-1;append(&out,"invalid push branch");goto done;}
    TRY(git_remote_lookup(&remote,r,arg));
    size_t size=2*strlen(paths[0])+32;char *spec=malloc(size);if(!spec){e=-1;goto done;}
    snprintf(spec,size,"refs/heads/%s:refs/heads/%s",paths[0],paths[0]);git_strarray refs={&spec,1};
    push_context ctx={&out,0};
    git_push_options opts=GIT_PUSH_OPTIONS_INIT;opts.callbacks.push_update_reference=pushStatus;opts.callbacks.credentials=credentials;opts.callbacks.payload=&ctx;
    e=git_remote_push(remote,&refs,&opts);free(spec);break;}
  case 16: /* tag at a resolved deferred commit id */
    if(count!=1 || strlen(paths[0])!=GIT_OID_HEXSZ){e=-1;append(&out,"tagAt needs a full commit id");goto done;}
    TRY(git_oid_fromstr(&oid,paths[0]));TRY(git_object_lookup(&obj,r,&oid,GIT_OBJECT_COMMIT));
    TRY(git_tag_create_lightweight(&oid,r,arg,obj,0));break;
  case 17: { /* prepare an unpublished commit; the caller journals undo before publishing */
    if(git_repository_head_detached(r)!=0 || git_repository_head_unborn(r)!=0){e=-1;append(&out,"compensable commit requires an existing attached branch");goto done;}
    TRY(git_repository_head(&ref,r));
    const git_oid *old=git_reference_target(ref);
    TRY(git_commit_lookup(&parent,r,old));TRY(git_repository_index(&idx,r));
    if(git_index_has_conflicts(idx)){e=-1;append(&out,"index has unresolved conflicts");goto done;}
    TRY(git_index_write_tree(&oid,idx));TRY(git_tree_lookup(&tree,r,&oid));
    if(git_oid_equal(git_tree_id(tree),git_commit_tree_id(parent))){e=-1;append(&out,"nothing staged to commit");goto done;}
    if(*name && *email)TRY(git_signature_now(&sig,name,email));else TRY(git_signature_default(&sig,r));
    TRY(git_commit_create(&oid,r,NULL,sig,sig,NULL,arg,tree,1,(const git_commit **)&parent));
    char before[GIT_OID_HEXSZ+1],after[GIT_OID_HEXSZ+1];
    git_oid_tostr(before,sizeof before,old);git_oid_tostr(after,sizeof after,&oid);
    append(&out,"%s\n%s\n%s\n",git_reference_name(ref),before,after);break;}
  case 18: case 19: { /* exact reference CAS; undo also accepts an already-restored reference */
    if(count!=2 || strlen(paths[0])!=GIT_OID_HEXSZ || strlen(paths[1])!=GIT_OID_HEXSZ){e=-1;append(&out,"reference CAS needs two full commit ids");goto done;}
    git_oid target,expected;TRY(git_oid_fromstr(&target,paths[0]));TRY(git_oid_fromstr(&expected,paths[1]));
    TRY(git_reference_lookup(&ref,r,arg));
    if(git_reference_type(ref)!=GIT_REFERENCE_DIRECT){e=-1;append(&out,"reference CAS refuses a symbolic reference");goto done;}
    if(op==19 && git_oid_equal(git_reference_target(ref),&target))break;
    TRY(git_reference_create_matching(&ref2,r,arg,&target,1,&expected,"Sol compensable commit"));break;}
  default:e=-1;append(&out,"unknown native Git operation");
  }
done:
  if(e<0 && !out.n){const git_error *err=git_error_last();append(&out,"%s",err?err->message:"native Git operation failed");}
  if(out.bad){free(out.p);out.p=strdup("native Git output limit or allocation failure");e=-1;}
  *result=out.p?out.p:strdup("");
  git_remote_free(remote);git_revwalk_free(walk);git_status_list_free(status);git_diff_free(diff);git_reference_free(ref2);git_reference_free(ref);
  git_signature_free(sig);git_commit_free(parent);git_tree_free(tree);git_object_free(obj);git_index_free(idx);git_repository_free(r);git_libgit2_shutdown();
  return e<0?-1:0;
}
