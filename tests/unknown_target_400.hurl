GET http://127.0.0.1:8080/foo/1.2.3.4

HTTP/1.1 400
[Asserts]
body == "Unknown target"
