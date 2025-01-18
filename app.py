# Core
import os
from datetime import timedelta
import pathlib as pl


# Flask
from flask import Flask, render_template, request, jsonify

BASE_DIR = pl.Path(__file__).parent

_static_folder =  BASE_DIR.joinpath('static').as_posix()
instance_dir = BASE_DIR.joinpath('instance').as_posix()

app = Flask(__name__, instance_path=instance_dir, static_folder=_static_folder, static_url_path='/static')
# Trying on Windows? Comment out __above__ line and use __below__ line!
# app = Flask(__name__, instance_path=instance_dir, static_path='/static', static_url_path='/static')

app.config.from_object('instance.default')
app.config.from_object('instance.{0}'.format(os.environ.get('APP_ENVIRONMENT', 'dev')))
app.config['BASE_DIR'] = BASE_DIR

app.logger.info('Starting Application')


@app.route('/')
def home():
    return render_template('index.html')


@app.errorhandler(404)
def page_not_found(e):
    return jsonify({"message": "page you are looking for can not be found!"}), 404


@app.errorhandler(500)
def internal_server_error(e):
    """
    Flask does not support having error handler in different blueprint!
    :param e: error
    :return: error page with error code
    """
    return jsonify({"message": "Internal Server Error"}), 500


@app.route('/test')
def test():
    d = {}
    for p in dir(request):
        d[p] = getattr(request, p)

    return jsonify(d)


if __name__ == '__main__':
    app.run(port=app.config['PORT'])

