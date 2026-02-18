#!/bin/bash
echo "=== pactl list cards ==="
pactl list cards
echo ""
echo "=== pactl list sinks ==="
pactl list sinks
echo ""
echo "=== wpctl status ==="
wpctl status
echo ""
echo "=== pw-cli ls Node ==="
pw-cli ls Node
