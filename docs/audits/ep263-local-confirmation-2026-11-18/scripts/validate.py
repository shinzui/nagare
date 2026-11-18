# Validate a document against a named schema of docs/api/openapi.json (OpenAPI 3.1 components).
import json, sys
import jsonschema
spec = json.load(open(sys.argv[1]))
doc = json.load(open(sys.argv[3]))
schema = {"$ref": "#/components/schemas/" + sys.argv[2], "components": spec["components"]}
jsonschema.Draft202012Validator(schema).validate(doc)
print("valid", sys.argv[2], sys.argv[3])
