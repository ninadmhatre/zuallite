__author__ = 'ninad'

import logging
from datetime import timedelta
import os

DEBUG = True
LOG_QUERIES = False
SECRET_KEY = '' # <-- EDIT_THIS
PORT = 5000
ADMIN_MAIL = 'ninad.mhatre@gmail.com'
LOGGER = {
    'FILE': dict(FILE='logs/log.log',
                 LEVEL=logging.DEBUG,
                 NAME='web_logger',
                 HANDLER='File',
                 FORMAT='%(asctime)s %(levelname)s %(filename)s %(module)s [at %(lineno)d line] %(message)s',
                 EXTRAS=dict(when='D', interval=1, backupCount=7))
}

ASSETS_DEBUG = False

permanent_session_lifetime = timedelta(minutes=240)
SESSION_TIMEOUT = timedelta(minutes=240)

# URL's
GIT_HUB = 'https://github.com/ninadmhatre'
LINKED_IN = 'https://linkedin.com/in/ninadmhatre'
EXTERNAL_BLOG = 'https://dev.to/ninadmhatre'
EXERCISM_RUST = 'https://exercism.org/profiles/ninadmhatre/solutions?track_slug=rust'
PERSONAL_EMAIL = ADMIN_MAIL

# Upload Folder
IMAGE_FOLDER = os.path.abspath('blog/img')

__VERSION__ = '25.1.1'
