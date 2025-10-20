#include "fileio.hpp"
#include <algorithm>
#include <cctype>
#include <cerrno>
#include <cstdio>
#include <cstring>
#include <fstream>
#include <map>
#include <sstream>
#include <string>
#include <tree_sitter/api.h>
#include <utility>
#include <vector>
#include <unistd.h>

using namespace std;

#define BUF_SIZE 1000005
#define eprintf(...) fprintf(stderr, __VA_ARGS__)

#define FIELD_DECLARATION_LIST "field_declaration_list"
#define STRUCT_SPECIFIER "struct_specifier"
#define FIELD_DECLARATION "field_declaration"
#define PREPROC_DEF "preproc_def"

#define MAX(a, b) ((a) > (b) ? (a) : (b))

extern "C" {
const TSLanguage *tree_sitter_c(void);
}

char source_code[BUF_SIZE];
long file_len;

typedef struct segment {
  uint32_t start;
  uint32_t end;
} segment;

vector<string> fields;
string emacs_src_dir;

int compare_seg(segment seg, char *ref) {
  if (strlen(ref) != seg.end - seg.start) {
    return -1;
  }
  for (int i = seg.start, j = 0; i < seg.end; i++, j++) {
    if (ref[j] != source_code[i]) {
      return -1;
    }
  }
  return 0;
}

string copy_segment(segment seg) {
  stringstream ss;
  for (int i = seg.start; i < seg.end; i++) {
    ss << source_code[i];
  }
  return ss.str();
}

string copy_node(TSNode *node) {
  if (ts_node_is_null(*node))
    return "";
  return copy_segment(segment{.start = ts_node_start_byte(*node),
                              .end = ts_node_end_byte(*node)});
}

int open_source_code(const char *path) {
  FILE *f = fopen(path, "r");
  if (f == NULL) {
    eprintf("failed to open %s: %s\n", path, strerror(errno));
    return -1;
  }
  file_len = fread(source_code, sizeof(char), BUF_SIZE, f);
  if (file_len < 0) {
    eprintf("failed to read\n");
    fclose(f);
    return -1;
  }
  fclose(f);
  return 0;
}

string struct_name(TSNode *struct_node) {
  TSNode name_node =
      ts_node_child_by_field_name(*struct_node, "name", strlen("name"));
  return copy_node(&name_node);
}

string node_type(TSNode *node) {
  if (node != NULL && !ts_node_is_null(*node))
    return ts_node_type(*node);
  return "";
}

TSNode find_first_match(TSNode *cur, bool (*pred)(TSNode *)) {
  if (pred(cur)) {
    return *cur;
  }

  int children_cnt = ts_node_child_count(*cur);
  for (int i = 0; i < children_cnt; i++) {
    TSNode child = ts_node_child(*cur, i);
    if (!ts_node_is_null(child)) {
      TSNode ret = find_first_match(&child, pred);
      if (!ts_node_is_null(ret)) {
        return ret;
      }
    }
  }
  return (TSNode){};
}

bool emacs_global_struct_p(TSNode *node) {
  if (node_type(node) == STRUCT_SPECIFIER) {
    return struct_name(node) == "emacs_globals";
  }
  return false;
}

bool field_list_p(TSNode *node) {
  return node_type(node) == FIELD_DECLARATION_LIST;
}

vector<pair<string, string>> collect_fields(TSNode *field_list) {
  vector<pair<string, string>> collection;
  if (node_type(field_list) != FIELD_DECLARATION_LIST) {
    return collection;
  }

  int children_cnt = ts_node_child_count(*field_list);
  for (int i = 0; i < children_cnt; i++) {
    TSNode child = ts_node_child(*field_list, i);
    if (ts_node_is_null(child))
      continue;
    if (node_type(&child) == FIELD_DECLARATION) {
      TSNode type = ts_node_child_by_field_name(child, "type", strlen("type"));
      TSNode declarator = ts_node_child_by_field_name(child, "declarator",
                                                      strlen("declarator"));
      collection.push_back(make_pair(copy_node(&type), copy_node(&declarator)));
    }
  }
  return collection;
}

vector<pair<string, string>> collect_macros(TSNode *field_list) {
  vector<pair<string, string>> collection;
  if (node_type(field_list) != FIELD_DECLARATION_LIST) {
    return collection;
  }

  int children_cnt = ts_node_child_count(*field_list);
  for (int i = 0; i < children_cnt; i++) {
    TSNode child = ts_node_child(*field_list, i);
    if (ts_node_is_null(child))
      continue;
    if (node_type(&child) == PREPROC_DEF) {
      TSNode name = ts_node_child_by_field_name(child, "name", strlen("name"));
      TSNode value =
          ts_node_child_by_field_name(child, "value", strlen("value"));
      collection.push_back(make_pair(copy_node(&name), copy_node(&value)));
    }
  }
  return collection;
}

pair<string, string> split(string str) {
  size_t pos = str.find('.');
  if (pos != string::npos) {
    return make_pair(str.substr(0, pos),
                     str.substr(pos + 1, str.length() - pos));
  }
  return make_pair(string(), string());
}

void dump_patch_header(const char *outputpath,
                       const vector<pair<string, string>> &macros,
                       map<string, string> vartype) {
  FILE *file = fopen(outputpath, "w");
  if (file == NULL) {
    eprintf("faield to open %s: %s\n", outputpath, strerror(errno));
    return;
  }

  fprintf(file, "#define DVARTRACK\n\n");
  // fprintf(file, "int dvar_initialize();\n\n");

  for (const pair<string, string> &macro : macros) {
    pair<string, string> varidp = split(macro.second);
    if (varidp.first != "globals" || vartype.count(varidp.second) == 0) {
      eprintf("unknown macro %s %s\n", macro.first.c_str(),
              macro.second.c_str());
      continue;
    }
    string varid = varidp.second;
    string funcname = "dvar_track_" + varid;

    // ignore dvar variables
    if (macro.first.size() > 5 && macro.first.compare(0, 5, "dvar_") == 0) continue;

    stringstream ss;
    ss << "#undef " << macro.first << "\n";
    ss << vartype[varid] << "* " << funcname << "(void);\n";
    ss << "#define " << macro.first << " "
       << "(*(" << funcname << "()))"
       << "\n";
    fprintf(file, "%s", ss.str().c_str());
  }
  fflush(file);
  fclose(file);

  printf("dumped to %s successfully\n", outputpath);
}

const char impl_template[] =
  "#include <config.h>\n\n"
  "#include \"lisp.h\"\n\n"
  "extern const char* dvar_record(void* varaddr, const char *varname);\n"
  "extern int dvar_backtracing;\n\n";

void dump_impl(const char *outputpath,
               const vector<pair<string, string>> &macros,
               map<string, string> vartype) {
  FILE *file = fopen(outputpath, "w");
  if (file == NULL) {
    eprintf("failed to open %s: %s\n", outputpath, strerror(errno));
    return;
  }

  fputs(impl_template, file);

  for (const pair<string, string> &macro : macros) {
    pair<string, string> varidp = split(macro.second);
    if (varidp.first != "globals" || vartype.count(varidp.second) == 0) {
      eprintf("unknown macro %s %s\n", macro.first.c_str(),
              macro.second.c_str());
      continue;
    }
    string varid = varidp.second;
    string funcname = "dvar_track_" + varid;
    
    stringstream ss;
    ss << vartype[varid] << "* " << funcname << "(void) {\n"
       << "    if (dvar_log_variable_access && !dvar_backtracing) {\n"
       << "        dvar_backtracing = 1;\n"
       << "        dvar_record(&" << macro.second << ", \"" << varid << "\");\n"
       // << "        const char* caller_name = dvar_impl(&" << macro.second
       // << ");\n"
       // << "        if (caller_name != NULL) {\n"
       // << "            fprintf(dvar_log_file, \"%s access " << varid << "\\n\", caller_name);\n"
       // << "        }\n"
       << "        dvar_backtracing = 0;\n"
       << "    }\n"
       << "    return &" << macro.second << ";\n}\n\n";
    fprintf(file, "%s", ss.str().c_str());
    printf("impl: %s\n", varid.c_str());
  }
  
  fflush(file);
  fclose(file);

  printf("dumped to %s successfully\n", outputpath);
}

using namespace std::filesystem;

struct TSFile {
  path filepath;
  char *buf;
  size_t bufsize;
  TSTree *parse_tree;

  TSFile(path filepath, char *buf, size_t bufsize, TSTree *parse_tree)
      : filepath(filepath), buf(buf), bufsize(bufsize), parse_tree(parse_tree) {
  }

  TSFile(TSFile &f) {
    filepath = f.filepath;
    buf = new char[f.bufsize];
    memcpy(buf, f.buf, f.bufsize);
    bufsize = f.bufsize;
    parse_tree = ts_tree_copy(f.parse_tree);
  }

  TSFile(TSFile &&f) noexcept
  : filepath(std::move(f.filepath)), buf(exchange(f.buf, (char*)NULL)),
        bufsize(exchange(f.bufsize, 0)),
        parse_tree(exchange(f.parse_tree, (TSTree*)NULL)) {}

  TSFile &operator=(TSFile &rval) {
    if (buf != NULL)
      delete buf;
    if (parse_tree != NULL)
      ts_tree_delete(parse_tree);

    filepath = rval.filepath;
    buf = new char[rval.bufsize];
    memcpy(buf, rval.buf, rval.bufsize);
    bufsize = rval.bufsize;
    parse_tree = ts_tree_copy(rval.parse_tree);
    return *this;
  }

  TSFile &operator=(TSFile &&rval) {
    if (buf != NULL)
      delete buf;
    if (parse_tree != NULL)
      ts_tree_delete(parse_tree);

    filepath = std::move(rval.filepath);
    buf = exchange(rval.buf, (char*)NULL);
    bufsize = exchange(rval.bufsize, 0);
    parse_tree = exchange(rval.parse_tree, (TSTree*)NULL);
    return *this;
  }

  ~TSFile() {
    if (buf != NULL)
      delete buf;
    if (parse_tree != NULL)
      ts_tree_delete(parse_tree);
  }

  int find_match(bool (*pred)(TSFile *self, TSNode *node),
                 void (*callback)(TSNode *matchnode));
  string node_text(TSNode *node);
  void traverse_tree(TSNode *cur, bool (*pred)(TSFile *self, TSNode *node),
                     void (*callback)(TSNode *matchnode));
};

TSFile parse_file(TSParser *parser, path filepath) {
  char *buf;
  size_t len = read_file(filepath, BUF_SIZE, &buf);
  TSTree *tree = ts_parser_parse_string(parser, NULL, buf, len);
  TSFile src(filepath, buf, len, tree);
  return src;
}

void TSFile::traverse_tree(TSNode *cur,
                           bool (*pred)(TSFile *self, TSNode *node),
                           void (*callback)(TSNode *matchnode)) {
  uint32_t children_cnt = ts_node_child_count(*cur);
  for (int i = 0; i < children_cnt; i++) {
    TSNode child = ts_node_child(*cur, i);
    if (pred(this, &child)) {
      // printf("traverse_tree: match %s\n", this->node_text(&child).c_str());
      callback(&child);
    }
    traverse_tree(&child, pred, callback);
  }
}

int TSFile::find_match(bool (*pred)(TSFile *self, TSNode *node),
                       void (*callback)(TSNode *matchnode)) {
  TSNode root_node = ts_tree_root_node(this->parse_tree);
  traverse_tree(&root_node, pred, callback);
  return 0;
}

string TSFile::node_text(TSNode *node) {
  uint32_t start = ts_node_start_byte(*node);
  uint32_t end = ts_node_end_byte(*node);
  stringstream ss;
  for (int i = start; i < end; i++) {
    ss << this->buf[i];
  }
  return ss.str();
}

vector<pair<string, string>> global_macros;

struct replacement {
  uint32_t start;
  uint32_t orig_len;
  uint32_t id_start;
  uint32_t id_len;
};

vector<replacement> replace_holder;

void list_ref_globals(TSFile *file) {
  bool (*pred)(TSFile *, TSNode *) = [](TSFile *fobj, TSNode *node) -> bool {
    if (node_type(node) == "pointer_expression") {
      const char argument[] = "argument";
      const size_t len = strlen(argument);
      TSNode child = ts_node_child_by_field_name(*node, argument, len);
      if (!ts_node_is_null(child) && node_type(&child) == "identifier") {
        string str = fobj->node_text(&child);
        for (const pair<string, string> &macro : global_macros) {
          if (macro.first == str) {
            // printf("pred: match %s\n", str.c_str());
            return true;
          }
        }
      }
    }
    return false;
  };

  void (*callback)(TSNode *) = [](TSNode *node) {
    const char argument[] = "argument";
    const size_t len = strlen(argument);
    TSNode child = ts_node_child_by_field_name(*node, argument, len);

    uint32_t startbyte = ts_node_start_byte(*node);
    uint32_t endbyte = ts_node_end_byte(*node);

    uint32_t id_start = ts_node_start_byte(child);
    uint32_t id_end = ts_node_end_byte(child);
    replacement rep = {
        .start = startbyte,
        .orig_len = endbyte - startbyte,
        .id_start = id_start,
        .id_len = id_end - id_start,
    };
    replace_holder.push_back(rep);
  };

  file->find_match(pred, callback);
}

int parse_args(int argc, char *argv[]) {
  int index = 0;
  int c = 0;
  char *tvalue = NULL;
  opterr = 0;

  while ((c = getopt (argc, argv, "t:")) != -1) {
    switch (c) {
    case 't':
      tvalue = optarg;
      break;
    case '?':
      if (optopt == 't')
        eprintf("Option -%c requires an argument.\n", optopt);
      else if (isprint(optopt))
        eprintf("Unknown option `-%c'.\n", optopt);
      else
        eprintf("Unknown option charactr `\\x%x'.\n", optopt);
      return 1;
    default:
      return -1;
    }
  }

  if (tvalue != NULL) {
    emacs_src_dir = string(tvalue);
  } else {
    eprintf("Option -t is required, please specified the path to the Emacs Source tree.\n");
    return 1;
  }
  
  return 0;
}

int main(int argc, char *argv[]) {
  if (parse_args(argc, argv) != 0) {
    return -1;
  }
  
  TSParser *parser = ts_parser_new();
  ts_parser_set_language(parser, tree_sitter_c());

  string src_path = emacs_src_dir + "/src/globals.h";
  if (open_source_code(src_path.c_str()) < 0) {
    eprintf("failed to open source code: %s\n", src_path.c_str());
    return -1;
  }

  TSTree *tree = ts_parser_parse_string(parser, NULL, source_code, file_len);

  if (tree == nullptr) {
    eprintf("failed to parse source code: %s\n", strerror(errno));
    return -1;
  }

  TSNode root_node = ts_tree_root_node(tree);
  TSNode globals_node = find_first_match(&root_node, &emacs_global_struct_p);
  TSNode field_list_node = find_first_match(&globals_node, &field_list_p);

  vector<pair<string, string>> fields = collect_fields(&field_list_node);
  vector<pair<string, string>> macros = collect_macros(&field_list_node);
  global_macros = macros;

  map<string, string> vartype;

  for (const pair<string, string> &field : fields) {
    vartype[field.second] = field.first;
  }
  map<string, string> global_refmap;
  for (const pair<string, string> &macro : macros) {
    pair<string, string> varidp = split(macro.second);
    if (varidp.first != "globals" || vartype.count(varidp.second) == 0) {
      eprintf("global_refmap: unknown macro %s %s\n", macro.first.c_str(),
              macro.second.c_str());
      continue;
    }
    string varid = varidp.second;
    // string funcname = "dvar_track_" + varid + "_ref";
    // global_refmap[macro.first] = funcname;
    global_refmap[macro.first] = macro.second;
  }

  vector<path> srcs = list_c_files(emacs_src_dir + "/src");
  
  for (const path &src : srcs) {
    TSFile ts = parse_file(parser, src);
    replace_holder.clear();
    list_ref_globals(&ts);
    for (const replacement &rep : replace_holder) {
      printf("%s: %d %d\n", src.c_str(), rep.start, rep.orig_len);
      for (int i = 0; i < rep.id_len; i++) {
        putchar(ts.buf[rep.id_start+i]);
      }
      putchar('\n');      
    }

    sort(replace_holder.begin(), replace_holder.end(),
         [](const replacement &rep1, const replacement &rep2) -> bool {
           return rep1.start < rep2.start;
         });

    if (replace_holder.size() == 0) continue;
    
    string outputname = src.string() + ".updated";
    printf("write update to %s\n", outputname.c_str());
    ofstream updatef;
    updatef.open(outputname, ofstream::out);
    int ignoring_counter = 0;
    vector<replacement>::iterator repit = replace_holder.begin();
    for (int i = 0; i < ts.bufsize; i++) {
      if (repit != replace_holder.end() && i == repit->start) {
        // insert replacement;
        stringstream ids;
        uint32_t st = repit->id_start;
        for (int j = 0; j < repit->id_len; j++) {
          ids << ts.buf[st + j];
        }
        string origid = ids.str();
        updatef << "&" << global_refmap[origid];
        ignoring_counter = repit->orig_len;
        repit++;
      }
      if (ignoring_counter > 0) {
        ignoring_counter--;
      } else {
        updatef << ts.buf[i];
      }
    }
    updatef.flush();
  }

  string patch_path = emacs_src_dir + "/src/globals_patch.h";
  dump_patch_header(patch_path.c_str(), macros, vartype);
  string impl_path = emacs_src_dir + "/src/dvar-func.c";
  dump_impl(impl_path.c_str(), macros, vartype);

  ts_tree_delete(tree);
  ts_parser_delete(parser);
  return 0;
}
