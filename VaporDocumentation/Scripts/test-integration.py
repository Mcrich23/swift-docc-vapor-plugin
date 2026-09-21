"""Exercise the fork's command against a small Vapor package and real DocC."""
# Copyright (c) 2026 Apple Inc. and the Swift project authors.
# Licensed under Apache License v2.0 with Runtime Library Exception.

import json
from pathlib import Path
import re
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[2]
FIXTURE = ROOT / 'VaporDocumentation/Tests/Fixtures/Server'
SCRATCH = ROOT / '.build/vapor-fixture'
EXPECTED = {'GET /health', 'GET /items', 'GET /items/:id',
            'GET /admin/:userID/items', 'GET /admin/:userID/items/:id'}


def run(fixture, command, *arguments, succeeds=True):
    result = subprocess.run(['swift', 'package', '--build-system', 'native',
                             '--scratch-path', str(SCRATCH), command,
                             '--target', 'Server', *arguments], cwd=fixture,
                            capture_output=True, text=True)
    output = result.stdout + result.stderr
    if succeeds != (result.returncode == 0):
        raise AssertionError(f'{command} exited {result.returncode}:\n{output}')
    if not succeeds:
        return output
    match = re.search(r'Generated documentation archive at:\s*\n\s*([^\r\n]+)', output)
    if not match:
        raise AssertionError(f'{command} succeeded without reporting an archive:\n{output}')
    return Path(match.group(1).strip())


def page(archive, relative):
    return json.loads((archive / relative).read_text())


def endpoints(archive):
    directory = archive / 'data/documentation/server'
    return {data['metadata']['title'] for path in directory.glob('*.json')
            if (data := json.loads(path.read_text()))['metadata'].get('symbolKind') == 'httpRequest'}


def descendants(nodes):
    for node in nodes:
        yield node
        yield from descendants(node.get('children', []))


def verify():
    with tempfile.TemporaryDirectory(prefix='vapor-docc-test-') as temporary:
        temporary = Path(temporary)
        fixture = temporary / 'Server'
        shutil.copytree(FIXTURE, fixture)
        (temporary / 'swift-docc-plugin').symlink_to(ROOT, target_is_directory=True)
        options = ('--vapor-routes', 'https://example.test/api')

        archive = run(fixture, 'generate-vapor-documentation', *options)
        assert endpoints(archive) == EXPECTED, (archive, endpoints(archive), EXPECTED)
        index = page(archive, 'index/index.json')
        nodes = list(descendants(index['interfaceLanguages']['swift']))
        groups = [node for node in nodes if node.get('title') == 'Endpoints']
        assert len(groups) == 1
        assert [node['title'] for node in groups[0]['children']
                if node.get('type') == 'groupMarker'] == ['/admin', '/health', '/items']
        assert EXPECTED <= {node.get('title') for node in nodes}

        route = page(archive, 'data/documentation/server/http-get-_2fitems.json')
        references = {item.get('title') for item in route['references'].values()}
        assert {'index(req:)', 'Item'} <= references
        assert route['abstract'][0]['text'] == 'List available items.'

        focused = run(fixture, 'generate-vapor-documentation', *options,
                      '--vapor-endpoints-only')
        assert endpoints(focused) == EXPECTED
        route = page(focused, 'data/documentation/server/http-get-_2fitems.json')
        references = {item.get('title') for item in route['references'].values()}
        assert 'Item' in references and 'index(req:)' not in references
        assert not (focused / 'data/documentation/server/itemcontroller.json').exists()

        failure = run(fixture, 'generate-vapor-documentation',
                      '--vapor-endpoints-only', succeeds=False)
        assert '--vapor-endpoints-only requires --vapor-routes' in failure

        source = fixture / 'Sources/Server/Server.swift'
        original = source.read_text()
        source.write_text(original.replace('    app.get("health") { _ in "OK" }\n', ''))
        updated = run(fixture, 'generate-vapor-documentation', *options)
        assert endpoints(updated) == EXPECTED - {'GET /health'}

        ordinary = run(fixture, 'generate-documentation')
        assert not endpoints(ordinary)

        source.write_text(original.replace('func routes(_ app: Application) throws {', '''
func routes(_ app: Application) throws {
    let path: PathComponent = "computed"
    app.get(path) { _ in "OK" }'''))
        failure = run(fixture, 'generate-vapor-documentation', *options,
                      '--warnings-as-errors', succeeds=False)
        assert 'dynamic route path' in failure
        assert 'Route extraction produced warnings' in failure


if __name__ == '__main__':
    verify()
    print('Vapor command integration passed.')
