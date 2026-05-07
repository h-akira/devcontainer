#!/usr/bin/env python3
# -*- coding: utf-8 -*-
#
# Created: <+DATE+>

import sys
import os

def parse_args():
  import argparse
  parser = argparse.ArgumentParser(description="""\
<+CURSOR+>
""", formatter_class = argparse.ArgumentDefaultsHelpFormatter)
  parser.add_argument("--version", action="version", version='%(prog)s 0.0.1')
  parser.add_argument("-o", "--output", metavar="output-file", default="output", help="output file")
  # parser.add_argument("-", "--", action="store_true", help="")
  parser.add_argument("file", metavar="input-file", help="input file")
  options = parser.parse_args()
  if not os.path.isfile(options.file): 
    raise Exception("The input file does not exist.") 
  return options

def main():
  options = parse_args()

if __name__ == '__main__':
  main()
