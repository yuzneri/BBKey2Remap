// kltool: load a key layout (.kl) with the unmodified Android 16 AOSP parser.
//   kltool check FILE   -> "OK", exit 1 if AOSP rejects the file
//   kltool dump FILE    -> "SCANCODE KEYLABEL FLAGS" for every mapped scan code below 1024
#include <input/KeyLayoutMap.h>
#include <cstdio>
#include <string>
namespace android { std::string statusToString(status_t s) { return std::to_string(s); } }
using namespace android;
const char* kcmtoolKeyLabel(int keyCode);

int main(int argc, char** argv) {
    std::string cmd = argc > 1 ? argv[1] : "";
    if ((cmd != "check" && cmd != "dump") || argc != 3) {
        fprintf(stderr, "usage: kltool check FILE | dump FILE\n");
        return 2;
    }
    auto r = KeyLayoutMap::load(std::string(argv[2]));
    if (!r.ok()) {
        fprintf(stderr, "PARSE_ERROR %s\n", argv[2]);
        return 1;
    }
    if (cmd == "check") {
        printf("OK\n");
        return 0;
    }
    for (int32_t scan = 0; scan < 1024; scan++) {
        int32_t keyCode;
        uint32_t flags;
        if ((*r)->mapKey(scan, 0, &keyCode, &flags) == OK) {
            const char* label = kcmtoolKeyLabel(keyCode);
            printf("%d %s 0x%x\n", scan, label ? label : "?", flags);
        }
    }
    return 0;
}
