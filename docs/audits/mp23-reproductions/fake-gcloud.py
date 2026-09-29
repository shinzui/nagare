#!/usr/bin/env python3
"""Local object transport recorder. Unknown commands fail; never invokes gcloud."""
import json
import os
from pathlib import Path
import sys

args = sys.argv[1:]
with open(os.environ['MP23_CALLS'], 'a') as output:
    output.write(json.dumps(args) + '\n')
root = Path(os.environ['MP23_OBJECTS'])
state_path = root / 'state.json'
state = json.loads(state_path.read_text()) if state_path.exists() else {'generation': 0, 'objects': {}}
objects = state['objects']
prefix = 'gs://audit.invalid/private/'

if args[:3] == ['storage', 'objects', 'describe']:
    item = objects.get(args[3])
    if item is None:
        sys.exit(1)
    print(item['generation'])
elif args[:3] == ['storage', 'objects', 'list']:
    print(json.dumps([{'name': url.removeprefix('gs://audit.invalid/')} for url in objects]))
elif args[:2] == ['storage', 'cp']:
    source, destination = args[2:4]
    if source.startswith(prefix):
        if source not in objects:
            sys.exit(1)
        Path(destination).write_text(objects[source]['bytes'])
    elif destination.startswith(prefix):
        condition = int(next(x.split('=')[1] for x in args if x.startswith('--if-generation-match=')))
        old = objects.get(destination)
        if destination.endswith('/head.json') and os.environ.get('MP23_RACE_HEAD') == '1' and not (root / 'raced').exists():
            assert old is not None
            head = json.loads(old['bytes'])
            head['generation'] += 1
            state['generation'] += 1
            objects[destination] = {'generation': state['generation'], 'bytes': json.dumps(head, sort_keys=True, separators=(',', ':'))}
            state_path.write_text(json.dumps(state))
            (root / 'raced').touch()
            old = objects[destination]
        if (old is not None if condition == 0 else old is None or old['generation'] != condition):
            sys.exit(1)
        state['generation'] += 1
        objects[destination] = {'generation': state['generation'], 'bytes': Path(source).read_text()}
        state_path.write_text(json.dumps(state))
        print(f"Created {destination}#{state['generation']}")
    else:
        raise SystemExit('unsupported local copy')
else:
    raise SystemExit('unsupported command')
