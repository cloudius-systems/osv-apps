// Copyright (C) 2026 Greg Burd
//
// This work is open source software, licensed under the terms of the
// BSD license as described in the LICENSE file in the top-level directory.
//
// ICU smoke test for OSv: open an ICU collator for two locales, sort the same
// word list under each, and print the resulting order. This proves ICU loads
// its data and runs on OSv, not merely that it links. The two locales are
// chosen to disagree: en-US and sv-SE order the Swedish letters differently
// (in Swedish, 'z' sorts before the accented vowels 'a-ring'/'a-diaeresis'/
// 'o-diaeresis', which come at the very end of the alphabet), so a correct ICU
// prints two different orders. Run the same program against ICU on the build
// host (same ICU version) to compare.
//
// Build: g++ -std=c++17 icu_smoke.cc -licui18n -licuuc -licudata

#include <unicode/coll.h>
#include <unicode/sortkey.h>
#include <unicode/locid.h>
#include <unicode/unistr.h>
#include <unicode/uvernum.h>

#include <algorithm>
#include <cstdio>
#include <string>
#include <vector>

// A word list mixing ASCII and Swedish letters so the two locales disagree.
// UTF-8 source; icu::UnicodeString::fromUTF8 decodes it.
static const char *WORDS[] = {
    "apple", "Apple", "banana", "zebra",
    "\xC3\xA4pple",      // "apple" with a-diaeresis (ae), Swedish 'ä'
    "\xC3\xB6l",         // "beer", Swedish 'ö'
    "\xC3\xA5r",         // "year", Swedish 'å'
    "orange",
};
static const int NWORDS = (int)(sizeof(WORDS) / sizeof(WORDS[0]));

static int sort_with_locale(const char *locale_id) {
    UErrorCode status = U_ZERO_ERROR;
    icu::Locale loc = icu::Locale::createCanonical(locale_id);
    icu::Collator *coll = icu::Collator::createInstance(loc, status);
    if (U_FAILURE(status) || coll == nullptr) {
        std::fprintf(stderr, "icu_smoke: createInstance(%s) failed: %s\n",
                     locale_id, u_errorName(status));
        return 1;
    }

    std::vector<std::string> words(WORDS, WORDS + NWORDS);
    std::sort(words.begin(), words.end(),
              [&](const std::string &a, const std::string &b) {
                  icu::UnicodeString ua = icu::UnicodeString::fromUTF8(a);
                  icu::UnicodeString ub = icu::UnicodeString::fromUTF8(b);
                  UErrorCode s = U_ZERO_ERROR;
                  return coll->compare(ua, ub, s) == UCOL_LESS;
              });

    std::printf("locale %-6s:", locale_id);
    for (const auto &w : words)
        std::printf(" %s", w.c_str());
    std::printf("\n");
    delete coll;
    return 0;
}

int main() {
    std::printf("icu_smoke: ICU %s\n", U_ICU_VERSION);
    int rc = 0;
    rc |= sort_with_locale("en-US");
    rc |= sort_with_locale("sv-SE");
    if (rc == 0)
        std::printf("icu_smoke: OK\n");
    return rc;
}
