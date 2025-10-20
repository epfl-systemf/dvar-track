#include <filesystem>
#include <string>
#include <vector>

std::vector<std::filesystem::path> list_c_files(std::string dirpath);

/* allocate a buffer, and read the file into the buffer.
   returns 0 when the file doesn't exist.
   the new allocated buf needs to be delete to avoid memory leak.
 */
size_t read_file(std::filesystem::path file, size_t maxbufsize, char **buf);

int backup_file(std::filesystem::path origfilename);
int restore_file(std::filesystem::path origfilename);

size_t write_file(std::filesystem::path file, size_t bufsize, char *buf);
