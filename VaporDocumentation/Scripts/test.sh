#!/bin/bash
#
# This source file is part of the Swift.org open source project
#
# Copyright (c) 2026 Apple Inc. and the Swift project authors
# Licensed under Apache License v2.0 with Runtime Library Exception
#
# See https://swift.org/LICENSE.txt for license information
# See https://swift.org/CONTRIBUTORS.txt for Swift project authors
#
set -euo pipefail
cd "$(dirname "$0")/../.."
SWIFT_SKIP_BUILDING_UPSTREAM_DOCC=true bin/test
python3 VaporDocumentation/Scripts/test-integration.py
python3 VaporDocumentation/Scripts/test-rebase.py
