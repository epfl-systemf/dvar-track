#ifndef DVAR_TRACK_H
#define DVAR_TRACK_H

extern union specbinding *backtrace_top (void);
extern bool backtrace_p (union specbinding *pdl);

extern int dvar_backtracing;

void syms_of_dvar_track(void);
void dvar_record(void *varaddr, const char* var_cname);

#endif
