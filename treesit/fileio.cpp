#include <algorithm>
#include <filesystem>
#include <fstream>
#include <iostream>
#include <string>
#include <vector>
#include "fileio.hpp"

using namespace std;
using namespace std::filesystem;

vector<path> list_c_files(string dirpath) {
  path p{dirpath};
  vector<path> files;

  for (const directory_entry &dir_entry : recursive_directory_iterator{p}) {
    cout << dir_entry.path() << endl;
    if (dir_entry.is_regular_file()) {
      path fp = dir_entry.path();
      if (fp.has_extension() &&
          (fp.extension() == ".c" || fp.extension() == ".h")) {
        files.push_back(fp);
      }
    }
  }
  return files;
}

size_t read_file(path file, size_t maxbufsize, char **buf) {
  if (!filesystem::exists(file)) {
    return 0;
  }
  ifstream is(file);
  if (is) {
    is.seekg(0, is.end);
    size_t length = is.tellg();
    is.seekg(0, is.beg);
    length = min(maxbufsize, length);
    *buf = new char[length];
    is.read(*buf, length);
    return length;
  }
  return 0;
}
