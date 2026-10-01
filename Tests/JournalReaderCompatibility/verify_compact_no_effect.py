#!/usr/bin/env python3
"""Schema 6/v1 vs schema 7/v2 using the actual immutable baseline SDK."""
import json
import pathlib
import shutil
import subprocess
import sys
import tempfile
import uuid
from verify import digest_tree, run, verify


def main():
    old, candidate, old_binary, new_binary = map(pathlib.Path, sys.argv[1:5])
    git = lambda p, ref: subprocess.check_output(['git', '-C', str(p), 'rev-parse', ref], text=True).strip()
    verify(git(old, 'HEAD') == 'e8ef319857ce651002504d6d3592fdcba7574172', 'actual schema-6 reader SHA')
    verify(git(old, 'HEAD^{tree}') == '3c860e28779e30148b7283944950ee94ae47b7cd', 'actual schema-6 reader tree')
    evidence = {'readerSHA': git(old, 'HEAD'), 'readerTree': git(old, 'HEAD^{tree}'),
                'candidateSHA': git(candidate, 'HEAD'), 'candidateTree': git(candidate, 'HEAD^{tree}'), 'cases': {}}
    session = uuid.uuid4()
    with tempfile.TemporaryDirectory(prefix='swiftagent-compact-matrix-') as temporary:
        root = pathlib.Path(temporary)
        legacy = root / 'legacy-v1'
        result = run(old_binary, 'create-no-effect', legacy, session)
        verify(result['exit'] == 0 and 'noEffectVersion=1' in result['output'], str(result))
        verify(json.loads((legacy / 'format.json').read_text())['schema'] == 6, 'real v1 schema')
        for action in ['inspect', 'append', 'maintain', 'inspect', 'exercise-no-effect-small', 'exercise-no-effect-large', 'inspect']:
            result = run(new_binary, action, legacy, session)
            evidence['cases'][f'new_{action}_v1'] = result
            verify(result['exit'] == 0 and 'noEffectVersion=1' in result['output'], str(result))
            verify(json.loads((legacy / 'format.json').read_text())['schema'] == 6, 'no automatic migration')
        for action in ['inspect', 'append', 'maintain']:
            result = run(old_binary, action, legacy, session)
            evidence['cases'][f'old_{action}_v1_after_new_writer'] = result
            verify(result['exit'] == 0 and 'noEffectVersion=1' in result['output'], str(result))
        for mode in ['create-no-effect-empty', 'create-no-effect']:
            store = root / mode
            result = run(new_binary, mode, store, session)
            verify(result['exit'] == 0, str(result))
            verify(json.loads((store / 'format.json').read_text())['schema'] == 7, 'explicit schema 7 at creation')
            for action in ['inspect', 'append', 'maintain']:
                copy = root / f'{mode}-{action}'
                shutil.copytree(store, copy)
                before = digest_tree(copy)
                result = run(old_binary, action, copy, session)
                untouched = before == digest_tree(copy)
                evidence['cases'][f'old_{action}_{mode}'] = result | {'untouched': untouched}
                verify(result['exit'] != 0 and 'unsupportedFormat' in result['output'] and untouched, str(result))
            for action in ['maintain', 'inspect']:
                result = run(new_binary, action, store, session)
                evidence['cases'][f'new_{action}_{mode}'] = result
                verify(result['exit'] == 0, str(result))
                if mode == 'create-no-effect': verify('noEffectVersion=2' in result['output'], 'v2 survives maintenance')
    print(json.dumps(evidence, indent=2, sort_keys=True))


if __name__ == '__main__':
    main()
