import sys
import os
import subprocess
import http.server
import socketserver
import threading
import socket
import logging

# 配置logging
logging.basicConfig(level=logging.INFO, # 设置日志级别
                    format='%(asctime)s - %(levelname)s - %(message)s',
                    handlers=[logging.StreamHandler(sys.stdout)]) # 输出到stdout
logger = logging.getLogger(__name__)

PORT = int(os.environ.get('PORT') or 3000) # http port
UUID = os.environ.get('UUID', '6877aae2-a8e7-44cc-ac29-c928eefa08e6')

class MyHandler(http.server.SimpleHTTPRequestHandler):

    def log_message(self, format, *args):
        # 如果需要HTTP服务器自身的请求日志，可以这样记录：
        # logger.info(format % args)
        pass # 当前设置为不记录HTTP服务器的请求日志

    def do_GET(self):
        if self.path == '/':
            self.send_response(200)
            self.end_headers()
            self.wfile.write(b'Hello, world')
        elif self.path == f"/{UUID}":
            try:
                with open("./sub.txt", 'rb') as file:
                    content = file.read()
                self.send_response(200)
                self.send_header('Content-Type', 'text/plain; charset=utf-8')
                self.end_headers()
                self.wfile.write(content)
            except FileNotFoundError:
                self.send_response(500)
                self.end_headers()
                self.wfile.write(b'Error reading file')
        else:
            self.send_response(404)
            self.end_headers()
            self.wfile.write(b'Not found')
logger.info(f"Attempting to bind to address: {PORT}")
httpd = socketserver.TCPServer(('', PORT), MyHandler, bind_and_activate=False)
httpd.allow_reuse_address = True  # 允许重用地址
try:
    httpd.server_bind()    # 手动绑定
    httpd.server_activate()  # 手动激活
except OSError as e:
    logger.error(f"Error binding or activating server on port {PORT}: {e}")
    sys.exit(1)
logger.info(f"Python HTTP server started on port {PORT} in a daemon thread.")
server_thread = threading.Thread(target=httpd.serve_forever)
server_thread.daemon = True
server_thread.start()

shell_command = "chmod +x start.sh && ./start.sh"

try:
    completed_process = subprocess.run(['bash', '-c', shell_command], stdout=sys.stdout, stderr=subprocess.PIPE, text=True, check=True)

    logger.info("App is running")

except subprocess.CalledProcessError as e:
    logger.info(f"Error: {e.returncode}")
    logger.info("Standard Output:")
    logger.info(e.stdout)
    logger.info("Standard Error:")
    logger.info(e.stderr)
    sys.exit(1)

server_thread.join()
