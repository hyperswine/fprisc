#!/usr/bin/env python3
"""Execute typed QOS x64 scalar/ABI emission using native Intel or Rosetta."""
import sys
from check_x64_scalar import main

if __name__ == '__main__':
    sys.argv.append('--qos')
    main()
