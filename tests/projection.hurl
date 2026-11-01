GET http://127.0.0.1:8080/ipv4/8.8.8.8?f=country.names.en,location.(latitude,longitude)
HTTP/1.1 200
Content-Type: application/json
[Asserts]
jsonpath "$.country.names.en" == "United States"
jsonpath "$.location.latitude" == 37.751
jsonpath "$.location.longitude" == -97.822
jsonpath "$.country.iso_code" not exists
jsonpath "$.continent" not exists
jsonpath "$.registered_country" not exists
