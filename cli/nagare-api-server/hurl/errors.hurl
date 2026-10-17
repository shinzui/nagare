# Every error is an RFC 9457 problem that is never stored.
GET {{base_url}}/v1/inventory/scopes/application:nope
If-None-Match: *
HTTP 404
[Asserts]
header "Content-Type" == "application/problem+json"
header "Cache-Control" == "no-store"
jsonpath "$.code" == "unknown_scope"
jsonpath "$.type" == "about:blank"

GET {{base_url}}/v1/sites?first=101
HTTP 400
[Asserts]
jsonpath "$.code" == "invalid_page"

GET {{base_url}}/v1/sites?after=not-a-cursor
HTTP 400
[Asserts]
jsonpath "$.code" == "invalid_cursor"

POST {{base_url}}/v1/inventory/head
HTTP 405
[Asserts]
header "Content-Type" == "application/problem+json"
jsonpath "$.code" == "method_not_allowed"

GET {{base_url}}/v1/inventory/head
Accept: text/html
HTTP 406
[Asserts]
jsonpath "$.code" == "not_acceptable"

GET {{base_url}}/v1/nothing
HTTP 404
[Asserts]
jsonpath "$.code" == "not_found"
