globals_parser: globals_parser.cpp fileio.o tree-sitter-c/libtree-sitter-c.a
	clang++ -g -o $@ -ltree-sitter $^

fileio.o: fileio.cpp fileio.hpp
	clang++ -g -c $<
