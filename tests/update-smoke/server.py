"""Bind a disposable loopback server, publish its chosen port, serve only this fixture."""
from http.server import ThreadingHTTPServer, SimpleHTTPRequestHandler
from functools import partial
from pathlib import Path
import sys
server = ThreadingHTTPServer(('127.0.0.1', 0), partial(SimpleHTTPRequestHandler, directory=sys.argv[1]))
Path(sys.argv[2]).write_text(str(server.server_port))
server.serve_forever()
