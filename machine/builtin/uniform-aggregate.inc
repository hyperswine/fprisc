/* Checked aggregate promotion. Included by arc.c, after scalar conversions.
 * The compiler supplies an ASCII graph and immortal field descriptors. This
 * worklist preserves DAG sharing and uses no C recursion, including on lists.
 * Shape references: 0 managed, 1 Word, 2 Addr, 3 F64, 4 F32, 5+ graph nodes.
 * Plan: U1 root nodes (tid variants (variant fields refs...)...) .
 * U2 checks every reachable field, including graphs requiring no copying:
 * refs 5 tagged Int/I32, 6 String, 7 Bool, 8 Unit, 9+ graph nodes.
 * U3 additionally records a scalar-storage flag after each node's tid.
 * Single-constructor scalar chains travel as their leaf internally; their
 * nominal boxes are reconstructed only at tagged boundaries.
 * One descriptor per variant, in plan order. Descriptor strings must be
 * immortal: the allocator borrows them for the converted object's lifetime.
 */
typedef struct { uw tid, first, count; int convert, scalar; char kind; } uniform_node;
typedef struct { uw tag, first, count; const str_t *layout; } uniform_variant;
typedef struct {
  V source, target;
  uw shape, variant, parent, next;
  int done;
} uniform_entry;
typedef struct {
  uniform_node *nodes;
  uniform_variant *variants;
  uw *fields, node_count, variant_count, field_count, root;
  uniform_entry *entries;
  uw *slots, count, capacity, slot_capacity;
  uw node_base, *scalar_path;
  int unbox, checked, storage;
} uniform_graph;
typedef struct { const uint8_t *p, *end; } uniform_reader;
#define UNIFORM_NONE (~(uw)0)
#define UNIFORM_DESCRIPTOR_TID 0x1fff0001u
static void uniform_bad(void) {
  fpr_cpanic("Builtin: uniform aggregate representation mismatch");
}
static uw uniform_number(uniform_reader *r) {
  while(r->p<r->end && *r->p==' ')r->p++;
  if(r->p==r->end || *r->p<'0' || *r->p>'9')uniform_bad();
  uw n=0;
  do {
    uw digit=*r->p++-'0';
    if(n>(UINTPTR_MAX-digit)/10)uniform_bad();
    n=n*10+digit;
  } while(r->p<r->end && *r->p>='0' && *r->p<='9');
  if(r->p<r->end && *r->p!=' ')uniform_bad();
  return n;
}
static void *uniform_array(uw count,uw width) {
  if(!count)return 0;
  if(count>UINTPTR_MAX/width)uniform_bad();
  return (void *)fpr_alloc(count*width);
}
static char uniform_kind(uniform_graph *g,uw ref) {
  return ref<5 ? "twadf"[ref] : ref<g->node_base ? 't' : g->nodes[ref-g->node_base].kind;
}
static void uniform_plan(uniform_graph *g,V plan,V descriptors) {
  if(!plan || ISINT(plan) || TID(plan)!=T_STR)uniform_bad();
  const str_t *s=(const str_t *)plan;
  if(s->len<3 || s->bytes[0]!='U' || (s->bytes[1]!='1' && s->bytes[1]!='2' && s->bytes[1]!='3') || s->bytes[2]!=' ')uniform_bad();
  g->storage=s->bytes[1]=='3';g->checked=s->bytes[1]!='1';g->node_base=g->checked?9:5;
  uniform_reader start={s->bytes+3,s->bytes+s->len}, r=start;
  g->root=uniform_number(&r);g->node_count=uniform_number(&r);
  if(g->node_count>s->len || g->root<g->node_base || g->root-g->node_base>=g->node_count)uniform_bad();
  /* Size from the supplied graph; no fixed type/arity/clone limits. */
  for(uw n=0;n<g->node_count;n++) {
    uniform_number(&r);if(g->storage && uniform_number(&r)>1)uniform_bad();
    uw variants=uniform_number(&r);
    if(variants>s->len-g->variant_count)uniform_bad();
    g->variant_count+=variants;
    for(uw v=0;v<variants;v++) {
      uniform_number(&r);uw fields=uniform_number(&r);
      if(fields>s->len-g->field_count)uniform_bad();
      g->field_count+=fields;
      for(uw f=0;f<fields;f++)if(uniform_number(&r)>=g->node_count+g->node_base)uniform_bad();
    }
  }
  while(r.p<r.end && *r.p==' ')r.p++;
  if(r.p!=r.end)uniform_bad();
  g->nodes=uniform_array(g->node_count,sizeof(*g->nodes));
  g->variants=uniform_array(g->variant_count,sizeof(*g->variants));
  g->fields=uniform_array(g->field_count,sizeof(*g->fields));
  r=start;uniform_number(&r);uniform_number(&r);
  uw vi=0,fi=0;
  for(uw n=0;n<g->node_count;n++) {
    uniform_node *node=&g->nodes[n];
    node->tid=uniform_number(&r);node->scalar=g->storage?(int)uniform_number(&r):0;
    node->first=vi;node->count=uniform_number(&r);
    node->convert=node->scalar;node->kind=node->scalar?0:'t';
    if(node->tid>UINT32_MAX || !node->count)uniform_bad();
    for(uw j=0;j<node->count;j++,vi++) {
      uniform_variant *v=&g->variants[vi];
      v->tag=uniform_number(&r);v->first=fi;v->count=uniform_number(&r);
      if(v->tag>UINT32_MAX)uniform_bad();
      for(uw prior=node->first;prior<vi;prior++)if(g->variants[prior].tag==v->tag)uniform_bad();
      if(!descriptors || ISINT(descriptors) || TID(descriptors)!=UNIFORM_DESCRIPTOR_TID ||
          ((hdr_t *)descriptors)->var!=1 || !fpr_in_heap(descriptors) ||
          fpr_builtin_field_count(descriptors)!=2)uniform_bad();
      V *pair=(V *)(descriptors+8);V descriptor=pair[0];descriptors=pair[1];
      if(!descriptor || ISINT(descriptor) || TID(descriptor)!=T_STR || fpr_in_heap(descriptor))uniform_bad();
      v->layout=(const str_t *)descriptor;
      if(v->layout->len!=v->count)uniform_bad();
      for(uw f=0;f<v->count;f++,fi++) {
        g->fields[fi]=uniform_number(&r);
      }
    }
  }
  if(!descriptors || ISINT(descriptors) || TID(descriptors)!=UNIFORM_DESCRIPTOR_TID || ((hdr_t *)descriptors)->var)uniform_bad();
  if(g->storage) {
    g->scalar_path=uniform_array(g->node_count,sizeof(*g->scalar_path));
    /* Resolve scalar chains iteratively and cache their physical kinds. A
     * cycle, boxed child, unknown slot or string is not scalar authority. */
    for(uw n=0;n<g->node_count;n++) {
      if(!g->nodes[n].scalar || g->nodes[n].kind)continue;
      uw depth=0,ref=n+g->node_base;char kind;
      for(;;) {
        if(ref<g->node_base) {
          if(ref==0 || ref==6)uniform_bad();
          kind=uniform_kind(g,ref);break;
        }
        uniform_node *node=&g->nodes[ref-g->node_base];
        if(!node->scalar || node->kind=='?')uniform_bad();
        if(node->kind) {kind=node->kind;break;}
        if(node->count!=1)uniform_bad();
        uniform_variant v=g->variants[node->first];
        if(v.count!=1)uniform_bad();
        node->kind='?';g->scalar_path[depth++]=ref-g->node_base;
        ref=g->fields[v.first];
      }
      while(depth)g->nodes[g->scalar_path[--depth]].kind=kind;
    }
  }
  for(uw vi=0;vi<g->variant_count;vi++) {
    uniform_variant v=g->variants[vi];
    for(uw f=0;f<v.count;f++)
      if(v.layout->bytes[f]!=uniform_kind(g,g->fields[v.first+f]))uniform_bad();
  }
  int changed;
  do {
    changed=0;
    for(uw n=0;n<g->node_count;n++) {
      uniform_node *node=&g->nodes[n];
      if(node->convert)continue;
      for(uw v=node->first;v<node->first+node->count;v++) {
        uniform_variant variant=g->variants[v];
        for(uw f=variant.first;f<variant.first+variant.count;f++) {
          uw ref=g->fields[f];
          if((ref>0 && ref<5) || (ref>=g->node_base && g->nodes[ref-g->node_base].convert))node->convert=1;
        }
      }
      changed|=node->convert;
    }
  } while(changed);
}
static uw uniform_hash(V source,uw shape) {
  uw n=(source>>3) ^ (shape*0x9e3779b97f4a7c15ULL);
  n^=n>>30;n*=0xbf58476d1ce4e5b9ULL;n^=n>>27;return n;
}
static uw uniform_slot(uniform_graph *g,V source,uw shape) {
  uw slot=uniform_hash(source,shape)&(g->slot_capacity-1);
  while(g->slots[slot]) {
    uniform_entry *e=&g->entries[g->slots[slot]-1];
    if(e->source==source && e->shape==shape)break;
    slot=(slot+1)&(g->slot_capacity-1);
  }
  return slot;
}
static void uniform_grow(uniform_graph *g) {
  /* Initial sizes only avoid tiny allocations; they are not admission caps. */
  uw capacity=g->capacity ? g->capacity*2 : 16;
  if(capacity<g->capacity || capacity>UINTPTR_MAX/2)uniform_bad();
  uniform_entry *entries=uniform_array(capacity,sizeof(*entries));
  for(uw i=0;i<g->count;i++)entries[i]=g->entries[i];
  if(g->entries)fpr_free((V)g->entries);
  if(g->slots)fpr_free((V)g->slots);
  g->entries=entries;g->capacity=capacity;g->slot_capacity=capacity*2;
  g->slots=uniform_array(g->slot_capacity,sizeof(*g->slots));
  for(uw i=0;i<g->slot_capacity;i++)g->slots[i]=0;
  for(uw i=0;i<g->count;i++)g->slots[uniform_slot(g,entries[i].source,entries[i].shape)]=i+1;
}
static V uniform_value(uniform_graph *,V,uw,uw,uw *);
static V uniform_scalar(uniform_graph *g,V source,uw shape) {
  uw depth=0;
  while(shape>=g->node_base) {
    uniform_node node=g->nodes[shape-g->node_base];
    uniform_variant v=g->variants[node.first];
    g->scalar_path[depth++]=shape-g->node_base;
    if(g->unbox) {
      if(!source || ISINT(source) || TID(source)!=node.tid ||
          ((hdr_t *)source)->var!=v.tag || !fpr_in_heap(source) ||
          fpr_builtin_field_count(source)!=1 || fpr_builtin_field_kind(source,0)!='t')uniform_bad();
      source=((V *)(source+8))[0]; /* borrowed until the owning root is released */
    }
    shape=g->fields[v.first];
  }
  uw ignored;
  V result=uniform_value(g,source,shape,UNIFORM_NONE,&ignored);
  if(!g->unbox)while(depth) {
    uniform_node node=g->nodes[g->scalar_path[--depth]];
    uniform_variant v=g->variants[node.first];
    V box=fpr_builtin_alloc_adt(8+sizeof(V),1);
    ((hdr_t *)box)->tid=node.tid;((hdr_t *)box)->var=v.tag;
    ((V *)(box+8))[0]=result;result=box;
  }
  return result;
}
static V uniform_value(uniform_graph *g,V source,uw shape,uw parent,uw *created) {
  *created=UNIFORM_NONE;
  if(!shape)return fpr_builtin_retain(source);
  if(shape<5) {
    unsigned variant=shape==1?2:shape==2?3:shape==3?5:6;
    unsigned width=shape==4?32:64;
    return g->unbox ? uniform_unbox(fpr_builtin_retain(source),variant,width)
                    : uniform_box(source,variant,width);
  }
  if(shape<g->node_base) {
    if(shape==5)fpr_fn__x24arc_x2euniformUnboxTagged(source);
    else if(shape==6)fpr_fn__x24arc_x2euniformUnboxText(source);
    else {
      fpr_fn__x24arc_x2euniformUnboxData(source,TAG(shape==7?T_BOOL:T_UNIT));
      if(((hdr_t *)source)->var>(shape==7?1u:0u) ||
          (fpr_in_heap(source) && fpr_builtin_field_count(source)!=0))uniform_bad();
    }
    return fpr_builtin_retain(source);
  }
  uniform_node node=g->nodes[shape-g->node_base];
  if(node.scalar)return uniform_scalar(g,source,shape);
  if(!source || ISINT(source) || TID(source)!=node.tid)uniform_bad();
  uw vi=node.first;
  while(vi<node.first+node.count && g->variants[vi].tag!=((hdr_t *)source)->var)vi++;
  if(vi==node.first+node.count)uniform_bad();
  uniform_variant v=g->variants[vi];
  if(fpr_in_heap(source)) {
    if(fpr_builtin_field_count(source)!=v.count)uniform_bad();
    for(uw f=0;f<v.count;f++)
      if(fpr_builtin_field_kind(source,f)!=(g->unbox?'t':uniform_kind(g,g->fields[v.first+f])))uniform_bad();
  } else if(v.count)uniform_bad();
  if(!v.count || (!node.convert && !g->checked))return fpr_builtin_retain(source);
  if(g->count==g->capacity)uniform_grow(g);
  uw slot=uniform_slot(g,source,shape);
  if(g->slots[slot]) {
    uniform_entry *e=&g->entries[g->slots[slot]-1];
    if(!e->done)fpr_cpanic("Builtin: cycle at uniform aggregate boundary");
    return fpr_builtin_retain(e->target);
  }
  if(v.count>(UINTPTR_MAX-8)/sizeof(V))uniform_bad();
  V target;
  if(node.convert) {
    target=fpr_builtin_alloc_adt(8+v.count*sizeof(V),v.count);
    ((hdr_t *)target)->tid=node.tid;((hdr_t *)target)->var=v.tag;
    for(uw f=0;f<v.count;f++)((V *)(target+8))[f]=(V)&fpr_unit;
    if(g->unbox)fpr_builtin_set_layout(target,(V)v.layout);
  } else target=fpr_builtin_retain(source); /* validate without copying */
  uw index=g->count++;
  g->entries[index]=(uniform_entry){source,target,shape,vi,parent,0,0};
  g->slots[slot]=index+1;*created=index;
  return fpr_builtin_retain(target); /* map and returned edge each own one */
}
V fpr_fn__x24arc_x2euniformAggregate(V source,V plan,V descriptors,V direction) {
  uniform_graph g={0};g.unbox=UNTAG(direction)!=0;
  uniform_plan(&g,plan,descriptors);
  uw current;
  V result=uniform_value(&g,source,g.root,UNIFORM_NONE,&current);
  while(current!=UNIFORM_NONE) {
    uniform_entry e=g.entries[current];
    uniform_variant v=g.variants[e.variant];
    if(e.next==v.count) {g.entries[current].done=1;current=e.parent;continue;}
    uw child;
    V converted=uniform_value(&g,((V *)(e.source+8))[e.next],g.fields[v.first+e.next],current,&child);
    if(g.nodes[e.shape-g.node_base].convert)((V *)(e.target+8))[e.next]=converted;
    else fpr_builtin_release(converted); /* source field already owns its edge */
    g.entries[current].next++;
    if(child!=UNIFORM_NONE)current=child;
  }
  if(g.unbox || !g.nodes[g.root-g.node_base].scalar)fpr_builtin_release(source);
  for(uw i=0;i<g.count;i++)fpr_builtin_release(g.entries[i].target);
  if(g.entries)fpr_free((V)g.entries);
  if(g.slots)fpr_free((V)g.slots);
  if(g.fields)fpr_free((V)g.fields);
  if(g.variants)fpr_free((V)g.variants);
  if(g.nodes)fpr_free((V)g.nodes);
  if(g.scalar_path)fpr_free((V)g.scalar_path);
  fpr_builtin_release(plan);fpr_builtin_release(descriptors);
  return result;
}
V fpr_fn__x24arc_x2euniformBoxAggregate(V value,V plan,V descriptors) {
  return fpr_fn__x24arc_x2euniformAggregate(value,plan,descriptors,TAG(0));
}
V fpr_fn__x24arc_x2euniformUnboxAggregate(V value,V plan,V descriptors) {
  return fpr_fn__x24arc_x2euniformAggregate(value,plan,descriptors,TAG(1));
}
V fpr_fn__x24arc_x2euniformBoxManaged(V value) {return value;}
V fpr_fn__x24arc_x2euniformUnboxManaged(V value) {return value;}
#undef UNIFORM_NONE
#undef UNIFORM_DESCRIPTOR_TID
