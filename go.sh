#!/bin/bash
echo "Enter commit message (e.g., Update to version 36):"
read -r message
git add .
git commit -m "$message"
git push origin main
