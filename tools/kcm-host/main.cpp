// kcmtool: load KCM files with the unmodified AOSP parser and evaluate them.
//   kcmtool check FILE                    -> "OK type=N", exit 1 if AOSP rejects the file
//   kcmtool eval FILE KEYLABEL METASTATE  -> result of one key event (METASTATE e.g. 0x4)
//   kcmtool eval-many FILE                -> reads "KEYLABEL METASTATE" lines on stdin, prints
//                                            "KEYLABEL METASTATE " + the result with key labels
//   kcmtool compare FILE_A FILE_B         -> one line per (key, meta state) whose result differs,
//                                            plus a "- type" line if the keyboard types differ
#include <input/KeyCharacterMap.h>
#include <input/InputEventLabels.h>
#include <android/keycodes.h>
#include <android/input.h>
#include <cstdio>
#include <cstdlib>
#include <string>
#include <vector>
namespace android { std::string statusToString(status_t s) { return std::to_string(s); } }
using namespace android;

static std::unique_ptr<KeyCharacterMap> load(const char* path) {
    auto r = KeyCharacterMap::load(std::string(path), KeyCharacterMap::Format::BASE);
    if (!r.ok()) {
        fprintf(stderr, "PARSE_ERROR %s\n", path);
        exit(1);
    }
    return std::move(*r);
}

/** Everything the framework derives from a KCM for one key event, as one comparable line. */
static std::string describe(const KeyCharacterMap& kcm, int32_t keyCode, int32_t meta) {
    auto [outKey, outMeta] = kcm.applyKeyBehavior(keyCode, meta);
    KeyCharacterMap::FallbackAction fb{};
    bool hasFb = kcm.getFallbackAction(keyCode, meta, &fb);
    char buf[160];
    snprintf(buf, sizeof buf, "key=%d meta=0x%x char=0x%04x fallback=%d/0x%x", outKey, outMeta,
             (unsigned)kcm.getCharacter(keyCode, meta), hasFb ? fb.keyCode : 0,
             hasFb ? fb.metaState : 0);
    return buf;
}

static std::string labelOf(int32_t keyCode) {
    const char* label = kcmtoolKeyLabel(keyCode);
    return label ? label : std::to_string(keyCode);
}

/** describe() with key labels instead of numbers, for comparison with the WebUI evaluator. */
static std::string describeLabels(const KeyCharacterMap& kcm, int32_t keyCode, int32_t meta) {
    auto [outKey, outMeta] = kcm.applyKeyBehavior(keyCode, meta);
    KeyCharacterMap::FallbackAction fb{};
    bool hasFb = kcm.getFallbackAction(keyCode, meta, &fb);
    char buf[200];
    snprintf(buf, sizeof buf, "key=%s meta=0x%x char=0x%04x fallback=%s/0x%x",
             labelOf(outKey).c_str(), outMeta, (unsigned)kcm.getCharacter(keyCode, meta),
             hasFb ? labelOf(fb.keyCode).c_str() : "-", hasFb ? fb.metaState : 0);
    return buf;
}

// Modifier states reaching a KCM. Held keys give side bit + general bit (updateMetaState +
// normalizeMetaState). For non-FULL keyboards such as type ALPHA, the framework text key listener
// also ORs in tapped (sticky) Shift/Alt/SYM as the general bit alone and a locked Shift as
// CAPS_LOCK (MetaKeyKeyListener.getMetaState, KeyEvent.normalizeMetaState). So each
// left/right group takes: none, general only, left, right, both.
struct Group { int32_t general, left, right; };
static const Group kGroups[] = {
        {AMETA_SHIFT_ON, AMETA_SHIFT_LEFT_ON, AMETA_SHIFT_RIGHT_ON},
        {AMETA_ALT_ON, AMETA_ALT_LEFT_ON, AMETA_ALT_RIGHT_ON},
        {AMETA_CTRL_ON, AMETA_CTRL_LEFT_ON, AMETA_CTRL_RIGHT_ON},
        {AMETA_META_ON, AMETA_META_LEFT_ON, AMETA_META_RIGHT_ON},
};
static const int32_t kFlags[] = {AMETA_SYM_ON, AMETA_FUNCTION_ON, AMETA_CAPS_LOCK_ON,
                                 AMETA_NUM_LOCK_ON, AMETA_SCROLL_LOCK_ON};

/** All modifier states compared: 5 per group times every flag subset (5^4 * 2^5 = 20000). */
static std::vector<int32_t> metaStates() {
    std::vector<int32_t> states{0};
    for (const Group& g : kGroups) {
        std::vector<int32_t> next;
        for (int32_t s : states) {
            for (int32_t add : {0, g.general, g.general | g.left, g.general | g.right,
                                g.general | g.left | g.right}) {
                next.push_back(s | add);
            }
        }
        states = std::move(next);
    }
    for (int32_t flag : kFlags) {
        size_t n = states.size();
        for (size_t i = 0; i < n; i++) states.push_back(states[i] | flag);
    }
    return states;
}

static int compare(const KeyCharacterMap& a, const KeyCharacterMap& b) {
    int differences = 0;
    if (a.getKeyboardType() != b.getKeyboardType()) {
        printf("- type %d | %d\n", (int)a.getKeyboardType(), (int)b.getKeyboardType());
        differences++;
    }
    const std::vector<int32_t> states = metaStates();
    for (int32_t keyCode = 1; keyCode <= KCMTOOL_KEYCODE_LIMIT; keyCode++) {
        const char* label = kcmtoolKeyLabel(keyCode);
        if (label == nullptr) continue;
        if (a.getDisplayLabel(keyCode) != b.getDisplayLabel(keyCode) ||
            a.getNumber(keyCode) != b.getNumber(keyCode)) {
            printf("%s properties label=0x%04x/0x%04x number=0x%04x/0x%04x\n", label,
                   (unsigned)a.getDisplayLabel(keyCode), (unsigned)b.getDisplayLabel(keyCode),
                   (unsigned)a.getNumber(keyCode), (unsigned)b.getNumber(keyCode));
            differences++;
        }
        for (int32_t meta : states) {
            std::string da = describe(a, keyCode, meta), db = describe(b, keyCode, meta);
            if (da != db) {
                printf("%s 0x%x %s | %s\n", label, meta, da.c_str(), db.c_str());
                differences++;
            }
        }
    }
    return differences;
}

int main(int argc, char** argv) {
    std::string cmd = argc > 1 ? argv[1] : "";
    if (cmd == "check" && argc == 3) {
        printf("OK type=%d\n", (int)load(argv[2])->getKeyboardType());
        return 0;
    }
    if (cmd == "eval" && argc == 5) {
        auto kcm = load(argv[2]);
        auto kc = InputEventLookup::getKeyCodeByLabel(argv[3]);
        if (!kc) {
            fprintf(stderr, "unknown key label %s\n", argv[3]);
            return 2;
        }
        printf("%s\n", describe(*kcm, *kc, (int32_t)strtol(argv[4], nullptr, 0)).c_str());
        return 0;
    }
    if (cmd == "eval-many" && argc == 3) {
        auto kcm = load(argv[2]);
        char key[64];
        char metaText[32];
        while (scanf("%63s %31s", key, metaText) == 2) {
            auto kc = InputEventLookup::getKeyCodeByLabel(key);
            if (!kc) {
                fprintf(stderr, "unknown key label %s\n", key);
                return 2;
            }
            printf("%s %s %s\n", key, metaText,
                   describeLabels(*kcm, *kc, (int32_t)strtol(metaText, nullptr, 0)).c_str());
        }
        return 0;
    }
    if (cmd == "compare" && argc == 4) {
        auto a = load(argv[2]), b = load(argv[3]);
        compare(*a, *b);
        return 0;
    }
    fprintf(stderr, "usage: kcmtool check FILE | eval FILE KEY META | eval-many FILE | compare A B\n");
    return 2;
}
