# The head reports open execution state and identifies its snapshot.
GET {{base_url}}/v1/inventory/head
HTTP 200
[Captures]
revision: header "Nagare-Head-Revision"
etag: header "ETag"
[Asserts]
header "Content-Type" contains "application/json"
header "Cache-Control" == "private, no-cache"
header "Vary" == "Authorization, Cookie, Accept"
jsonpath "$.revision" == "{{revision}}"
jsonpath "$.activeTransaction" == "tx-open"
jsonpath "$.transition.target" == "nagare-0.6.3-source"

GET {{base_url}}/v1/inventory/head
If-None-Match: "other", W/{{etag}}
HTTP 304
[Asserts]
header "Nagare-Head-Revision" == "{{revision}}"
bytes count == 0

HEAD {{base_url}}/v1/inventory/head
HTTP 200
[Asserts]
header "ETag" == "{{etag}}"
bytes count == 0

# Scope pages walk forward without repeating a scope.
GET {{base_url}}/v1/inventory/scopes?first=2
HTTP 200
[Captures]
first_scope: jsonpath "$.edges[0].node.scope"
cursor: jsonpath "$.pageInfo.endCursor"
[Asserts]
jsonpath "$.edges" count == 2
jsonpath "$.pageInfo.hasNextPage" == true

GET {{base_url}}/v1/inventory/scopes?first=2&after={{cursor}}
HTTP 200
[Asserts]
jsonpath "$.edges" count == 2
jsonpath "$.edges[0].node.scope" != "{{first_scope}}"
jsonpath "$.pageInfo.hasPreviousPage" == true

GET {{base_url}}/v1/inventory/scopes/standalone:site-s12
HTTP 200
[Asserts]
jsonpath "$.converged" == false
jsonpath "$.convergedRevision" == null

GET {{base_url}}/v1/inventory/publications
HTTP 200
[Asserts]
jsonpath "$.edges[0].node.resourceId" == "publication:app-image-docs-v1/docs-v1/oci-image"
jsonpath "$.edges[0].node.usedBy[0]" == "application:docs"
