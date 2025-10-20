#include <config.h>
#include <stdio.h>

#include "lisp.h"
#include "dvar-track.h"

int dvar_backtracing;

/* FILE *dvar_log_file;

int dvar_initialize() {
  dvar_log_file = fopen("./dvar_variable_log.txt", "w");
  dvar_backtracing = 0;
  return 1;
}

*/

void
syms_of_dvar_track() {
    DEFVAR_BOOL("dvar-log-variable-access", dvar_log_variable_access,
		doc: /* If non-nil, logging variables whenever they are accessed by C source code */);
    DEFVAR_LISP("dvar-function-dependency", dvar_function_dependency,
		doc: /* a hash-table maps function symbol to set of variable. */);
    dvar_log_variable_access = false;
    dvar_function_dependency = make_hash_table(&hashtest_eq, DEFAULT_HASH_SIZE, Weak_None, false);
}

/*
const char* dvar_top_subr_name() {
  dvar_backtracing = 1;
  union specbinding *pdl = backtrace_top();
  Lisp_Object fun = NULL;
  struct Lisp_Subr *topsubr = NULL;

  if (!backtrace_p(pdl)) {
    dvar_backtracing = 0;
    return NULL;
  }

  fun = pdl->bt.function;
  if (SYMBOLP (fun) && !NILP (fun)
      && (fun = XSYMBOL (fun)->u.s.function, SYMBOLP (fun)))
    fun = indirect_function (fun);

  if (!SUBRP(fun) || NATIVE_COMP_FUNCTION_DYNP(fun)) {
    dvar_backtracing = 0;
    return NULL;
  }

  topsubr = XSUBR(fun);

  dvar_backtracing = 0;
  return topsubr->symbol_name;
}
 */

// copied from eval.c
static Lisp_Object
specpdl_symbol (union specbinding *pdl)
{
  eassert (pdl->kind >= SPECPDL_LET);
  return pdl->let.symbol;
}

static int
dvar_let_bound_after(union specbinding *pdl, void *varaddr) {
  while (pdl < specpdl_ptr) {
    if (pdl->let.kind == SPECPDL_LET) {
      Lisp_Object sym = specpdl_symbol(pdl);
      if (SYMBOLP (sym)) {
	struct Lisp_Symbol *symbol = XSYMBOL (sym);
	if (symbol->u.s.redirect == SYMBOL_FORWARDED) {
	  // symbol on the stack cannot be an alias of the other variable
	  void *valaddr = NULL;
	  switch (XFWDTYPE(symbol->u.s.val.fwd)) {
	  case Lisp_Fwd_Int:		/* Fwd to a C `int' variable.  */
	    valaddr = ((struct Lisp_Intfwd const*)(symbol->u.s.val.fwd.fwdptr))->intvar;
	    break;
	  case Lisp_Fwd_Bool:		/* Fwd to a C boolean var.  */
	    valaddr = ((struct Lisp_Boolfwd const*)(symbol->u.s.val.fwd.fwdptr))->boolvar;
	    break;
	  case Lisp_Fwd_Obj:		/* Fwd to a C Lisp_Object variable.  */
	    valaddr = ((struct Lisp_Objfwd const*)(symbol->u.s.val.fwd.fwdptr))->objvar;
	    break;
	  default:
	    // TODO?
	    // Lisp_Fwd_Buffer_Obj
	    // Lisp_Fwd_Kboard_Obj
	    break;
          };

	  if (valaddr == varaddr) {
	    break;
	  }
	}
      }
    }
    pdl++;
  }
  return pdl < specpdl_ptr ? 1 : 0;
}

static const char *
dvar_top_subr_name(union specbinding *pdl) {
  Lisp_Object fun = pdl->bt.function;
  if (SYMBOLP(fun) && !NILP(fun)
      && (fun = XSYMBOL (fun)->u.s.function, SYMBOLP (fun)))
    fun = indirect_function (fun);

  if (!SUBRP (fun) || NATIVE_COMP_FUNCTION_DYNP (fun)) {
    return "unknown";
  }

  struct Lisp_Subr *topsubr = XSUBR(fun);
  return topsubr->symbol_name;
}

const char*
dvar_impl(void *varaddr) {
  union specbinding *pdl = backtrace_top();
  if (backtrace_p(pdl)) {
    if (!dvar_let_bound_after(pdl, varaddr)) {
      return dvar_top_subr_name(pdl);
    }
    return NULL;
  }
  return "NOFUNCALL";
}

static Lisp_Object
dvar_top_function(union specbinding *pdl) {
  Lisp_Object fun = pdl->bt.function;
  if (SYMBOLP(fun) && !NILP(fun)
      && (fun = XSYMBOL (fun)->u.s.function, SYMBOLP (fun)))
    fun = indirect_function (fun);
  return fun;
}

static void
CHECK_HASH_TABLE (Lisp_Object x)
{
  CHECK_TYPE (HASH_TABLE_P (x), Qhash_table_p, x);
}

static struct Lisp_Hash_Table *
check_hash_table (Lisp_Object obj)
{
  CHECK_HASH_TABLE (obj);
  return XHASH_TABLE (obj);
}

void
dvar_record(void *varaddr, const char* var_cname) {
  union specbinding *pdl = backtrace_top();
  if (backtrace_p (pdl) && !dvar_let_bound_after(pdl, varaddr)) {
    Lisp_Object topfun = dvar_top_function(pdl);
    Lisp_Object funsym = Qnil;
    if (SUBRP (topfun) && !NATIVE_COMP_FUNCTION_DYNP (topfun)) {
      struct Lisp_Subr *topsubr = XSUBR(topfun);
      funsym = intern_c_string_1(topsubr->symbol_name, strlen(topsubr->symbol_name));
    } else {
      return;
    }
    
    struct Lisp_Hash_Table *h = check_hash_table (dvar_function_dependency);       
    ptrdiff_t i = hash_lookup(h, funsym);
    if (i < 0) {
      EMACS_UINT hash = hash_from_key (h, funsym);
      i = hash_put(h, funsym, make_hash_table(&hashtest_equal, DEFAULT_HASH_SIZE, Weak_None, false), hash);
    }
    
    Lisp_Object subtable = HASH_VALUE(h, i);
    struct Lisp_Hash_Table *h1 = check_hash_table (subtable);
    Lisp_Object name_lisp_str = build_string(var_cname);
    ptrdiff_t i1 = hash_lookup(h1, name_lisp_str);
    if (i1 < 0) {
      EMACS_UINT hash1 = hash_from_key(h1, name_lisp_str);
      hash_put(h1, name_lisp_str, Qt, hash1);
    }
  }
}

/*
void dvar_indirect_function_template() {
  if (dvar_log_variable_access && !dvar_backtracing) {
    dvar_backtracing = 1;
    const char* caller_name = dvar_impl([ADDR_PLACE_HOLDER]);
    if (caller_name != NULL) {
        fprintf(dvar_log_file, "%s access [VAR_NAME_PLACE_HOLDER]", caller_name);
    }
    union specbinding *pdl = backtrace_top();
    dvar_backtracing = 0;
  }
  return;
}
*/
