from osv.modules import api

# ICU as an osv-apps library module.
#
# As a dependency (another module does api.require('icu')), this module just
# contributes its usr.manifest: the ICU shared libraries, the ICU data and the
# smoke-test binary. As a standalone image (image=icu) the default command runs
# the smoke test, which opens an ICU collator for two locales, sorts a word
# list and prints the order (see icu_smoke.cc). The usr.manifest is produced by
# build.sh (not here), because module.py is imported during dependency
# resolution, before 'make module' runs.
default = api.run('/usr/bin/icu_smoke')
