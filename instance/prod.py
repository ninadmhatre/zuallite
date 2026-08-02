__author__ = 'ninad'

import os

# instance/default.py sets DEBUG = True, which is fine for dev but must not
# reach production -- it turns tracebacks and app config into a public endpoint.
DEBUG = False
ASSETS_DEBUG = False
LOG_QUERIES = False

# Unused today (the app has no sessions or flash messages), but wired up so
# that adding either later does not silently run on an empty key.
SECRET_KEY = os.environ.get('SECRET_KEY', '')
