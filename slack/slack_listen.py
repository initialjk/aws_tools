import logging
import os
import subprocess
from logging.handlers import RotatingFileHandler

from flask import Flask, request, Response, jsonify

app = Flask(__name__)

SLACK_WEBHOOK_SECRET = os.environ.get('SLACK_WEBHOOK_SECRET', None)
AUTHORIZED_USER = ('john.dow')


def check_perm(username):
    return username in AUTHORIZED_USER


def shell_exec(command):
    app.logger.debug("$ %s", command)
    proc = subprocess.Popen(command, shell=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    if 0 != proc.wait():
        msg = '\n'.join([proc.stdout.read(), proc.stderr.read()])
        app.logger.error("Error by command: %s\n%s", command, msg)
        raise SystemError("Failed to execute: %s" % command)
    else:
        msg = proc.stdout.read()
        app.logger.debug("%s", msg)
        return msg


class SlackCommands:
    def format_result(self, results):
        msg = ''
        if results:
            msg += '\n'.join(results)

        current_block = shell_exec("iptables -nL FORWARD | grep DROP | tr -s ' ' | cut -f 4 -d ' '")
        if current_block:
            msg += "\nBlocked addresses.\n```" + current_block + "```"
        else:
            msg += "\nThere is no blocked hosts."
        return msg

    def blocking(self, args):
        results = []
        for addr in args:
            if addr.startswith('-'):
                addr = addr.lstrip('-')
                app.logger.info('Try to unblock address: %s', addr)
                try:
                    shell_exec("iptables -D FORWARD -s %s -j DROP" % addr)
                    results.append("Address %s is successfully unblocked." % addr)
                except SystemError:
                    results.append("Failed to unblock address '%s'." % addr)
            else:
                app.logger.info('Try to block address: %s', addr)
                try:
                    shell_exec("iptables -A FORWARD -s %s -j DROP" % addr)
                    results.append("Address %s is successfully blocked." % addr)
                except SystemError:
                    results.append("Failed to block address '%s'." % addr)
        return self.format_result(results)

command = SlackCommands()

@app.route('/slack', methods=['POST'])
def inbound():
    if SLACK_WEBHOOK_SECRET is None or SLACK_WEBHOOK_SECRET == request.form.get('token'):
        channel = request.form.get('channel_name')
        username = request.form.get('user_name')
        text = request.form.get('text')
        app.logger.info("%s in %s says: %s", username, channel, text)

        if not channel or not username or not text:
            return Response(), 400

        if not check_perm(username):
            return jsonify(dict(text="You don't have permission to do `%s`." % text))

        try:
            args = text.split()
            method_name = args[0].lstrip('!')
            app.logger.info("User '%s' has executed command '%s': %s (from channel %s)",
                            username, method_name, text, channel)
            result = getattr(command, method_name)(args[1:])
            return jsonify(dict(text=result))
        except AttributeError:
            return Response(), 404
    return Response(), 403


if __name__ == "__main__":
    handler = RotatingFileHandler('slack.log', maxBytes=1024, backupCount=2)
    handler.setLevel(logging.INFO)
    app.logger.setLevel(logging.INFO)
    app.logger.addHandler(handler)
    app.run(host='0.0.0.0')

