<!--
 Copyright 2026 mohitvaish
 
 Licensed under the Apache License, Version 2.0 (the "License");
 you may not use this file except in compliance with the License.
 You may obtain a copy of the License at
 
     https://www.apache.org/licenses/LICENSE-2.0
 
 Unless required by applicable law or agreed to in writing, software
 distributed under the License is distributed on an "AS IS" BASIS,
 WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 See the License for the specific language governing permissions and
 limitations under the License.
-->
# Coding Standards

## Solidity Version

All protocol contracts must use Solidity 0.8.30.

## Dependencies

Use OpenZeppelin v5 for standard contract building blocks.

Prefer established, audited libraries over custom implementations when they fit the protocol requirements.

## Documentation

All public and external functions must include NatSpec documentation.

NatSpec should describe purpose, parameters, return values, access restrictions, and important side effects.

## Errors

Use custom errors instead of revert strings where practical.

Custom errors should be specific enough to make failed calls clear during testing, debugging, and audits.

## Events

Emit events for meaningful state changes.

Events should support indexing, monitoring, audits, and off-chain integration.

## Assembly

Inline assembly is not allowed unless explicitly approved.

Any approved assembly must include a clear reason and focused tests.

## Imports

Use named imports.

Avoid wildcard imports so dependencies remain explicit and reviewable.

## Formatting

Use consistent formatting with `forge fmt`.

Formatting changes should not be mixed with unrelated logic changes unless needed for the current task.
