class_name EuroWallet
extends RefCounted

## Integer-cent wallet. Only the economy manager should credit this wallet.

var _balance_cents := 50000


func get_balance_cents() -> int:
	return _balance_cents


func credit_reward(amount_cents: int) -> bool:
	if amount_cents <= 0 or _balance_cents > 2147483647 - amount_cents:
		return false
	_balance_cents += amount_cents
	return true


func restore_balance_cents(value: int) -> bool:
	if value < 0 or value > 2147483647:
		return false
	_balance_cents = value
	return true


func format_balance() -> String:
	return "€%d.%02d" % [int(_balance_cents / 100), _balance_cents % 100]
