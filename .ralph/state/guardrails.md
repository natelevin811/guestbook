# Guardrails

> STOP. Read these before every action.

## Non-Interactive Commands Only

**NEVER** run commands that wait for input. Always use flags:
- `npm init -y` (not `npm init`)
- `git commit -m "msg"` (not `git commit`)
- `python script.py` (not `python`)
- `node script.js` (not `node`)

## Safe Workflow

1. **Read before write** - Check file contents before editing
2. **Test after changes** - Run tests to verify
3. **Commit checkpoints** - Save state before risky changes

---

## Learned Failures

_(Added automatically when errors occur)_

