# Building

1. Install nim and nimble.
2. `nimble build`

# Testing

DIY testing:

```
./gen_native_message.py cmd..getconfigpath | ./native_main | cut -b4- | jq 'walk( if type == "object" then with_entries(select(.value != null)) else . end)'
```

Swap `native_main` for the old `native_main.py` messenger to check compat.
