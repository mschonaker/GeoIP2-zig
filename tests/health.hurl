GET http://127.0.0.1:8080/health

HTTP/1.1 200
[Asserts]
body == "OK"
