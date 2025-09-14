import 'package:flutter/material.dart';
import 'package:math_expressions/math_expressions.dart';

void main() {
  runApp(const CalculatorApp());
}

class CalculatorApp extends StatelessWidget {
  const CalculatorApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Kyle Mard',
      theme: ThemeData(useMaterial3: true, colorSchemeSeed: Colors.blue),
      home: const CalculatorPage(),
      debugShowCheckedModeBanner: false,
    );
  }
}

class CalculatorPage extends StatefulWidget {
  const CalculatorPage({super.key});

  @override
  State<CalculatorPage> createState() => _CalculatorPageState();
}

class _CalculatorPageState extends State<CalculatorPage> {
  String _expression = '';
  String _result = '';
  String _error = '';

  String _lastOperator = '';
  String _lastOperand = '';
  bool _limitReached = false;

  double? _lastValue; // last finite numeric value

  // ===== Precision / magnitude guardrails =====

  // Use Dart's bound for safety
  static const double _maxMagnitude = double.maxFinite;

  // Your reflexive "lower from upper" (≈ 1 / 1.79e308 ≈ 5.56e-309)
  // You can swap this to 2.2250738585072014e-308 if you prefer min-normal.
  static const double _minNormalMagnitude = 1 / _maxMagnitude;

  // Exact integer precision ceiling (2^53)
  static const double _maxExactInt = 9007199254740992;

  // Division chain protections
  int _sequentialDivisions = 0;
  static const int _maxSequentialDivisions = 512;      // hard cap on repeated ÷
  static const double _earlyDivisionCutoff = _minNormalMagnitude; // stay above your lower limit

  // ==== NEW: decreasing-only monotonic trend tracking ====
  // -1 => expect decreasing magnitude; 0 => no expectation
  int _monotonicTrend = 0;

  // Tiny tolerance to ignore FP wiggles
  static const double _relEps = 1e-12;

  bool _checkFloatLimits(double value) {
    if (!value.isFinite) {
      _error = 'Overflow';
      _limitReached = true;
      return false;
    }
    final absV = value.abs();
    if (absV > _maxMagnitude) {
      _error = 'Overflow';
      _limitReached = true;
      return false;
    }
    // Treat anything between 0 and your lower cutoff as underflow.
    if (absV != 0.0 && absV < _minNormalMagnitude) {
      _error = 'Underflow';
      _limitReached = true;
      return false;
    }
    return true;
  }

  bool _isPureIntegerExpression(String expr) {
    if (expr.isEmpty) return false;
    if (expr.contains('.') || expr.contains('÷')) return false;
    return RegExp(r'^[0-9+\-×]+$').hasMatch(expr);
  }

  bool _nearInteger(double v) => (v - v.round()).abs() < 1e-9;

  String _formatNumber(double v, {required bool intMode}) {
    if (intMode && _nearInteger(v)) return v.round().toString();
    if (!intMode && _nearInteger(v) && v.abs() < 1e15) return v.round().toString();
    if (v.abs() >= 1e12 || (v.abs() > 0 && v.abs() < 1e-6)) {
      return v
          .toStringAsExponential(10)
          .replaceFirst(RegExp(r'0+e'), 'e')
          .replaceFirst(RegExp(r'\.0+e'), 'e');
    }
    return v.toString();
  }

  double? _evaluate(String raw) {
    final exp = raw.replaceAll('×', '*').replaceAll('÷', '/');
    Parser p = Parser();
    Expression e = p.parse(exp);
    ContextModel cm = ContextModel();
    return e.evaluate(EvaluationType.REAL, cm);
  }

  void _storeRepeatData(String expressionJustEvaluated) {
    final regex = RegExp(r'([+\-×÷])\s*([\d.]+)\s*$');
    final match = regex.firstMatch(expressionJustEvaluated);
    if (match != null) {
      _lastOperator = match.group(1)!;
      _lastOperand = match.group(2)!;

      // === Only track decreasing sequences ===
      //   ÷ by > 1  => decreasing magnitude
      //   × by 0 < k < 1 => decreasing magnitude
      _monotonicTrend = 0;
      final opnd = double.tryParse(_lastOperand);
      if (opnd != null && opnd > 0) {
        if (_lastOperator == '÷' && opnd > 1.0) {
          _monotonicTrend = -1;
        } else if (_lastOperator == '×' && opnd < 1.0) {
          _monotonicTrend = -1;
        }
      }
    } else {
      _lastOperator = '';
      _lastOperand = '';
      _monotonicTrend = 0;
    }
  }

  bool _finalize(double value, {required bool intMode, String? op}) {
    // General float checks (covers NaN/Inf and tiny non-zero via lower cutoff)
    if (!_checkFloatLimits(value)) return false;

    // Detect “quiet underflow to exactly 0.0” after ×/÷
    if ((op == '÷' || op == '×') &&
        _lastValue != null &&
        _lastValue!.abs() > 0.0 &&
        value == 0.0) {
      _error = 'Underflow';
      _limitReached = true;
      return false;
    }

    // === NEW: decreasing-only reversal guard ===
    // If we expect decreasing magnitude, the next |value| must be < previous by at least _relEps.
    if ((op == '÷' || op == '×') && _lastValue != null && _monotonicTrend == -1) {
      final prevAbs = _lastValue!.abs();
      final curAbs  = value.abs();
      if (curAbs >= prevAbs * (1.0 - _relEps)) {
        _error = 'Precision limit';
        _limitReached = true;
        return false;
      }
    }

    // Division-specific early cutoff & sequence limits
    if (op == '÷') {
      _sequentialDivisions++;

      // Early magnitude cutoff (stay above your lower limit)
      if (value != 0.0 && value.abs() < _earlyDivisionCutoff) {
        _error = 'Underflow';
        _limitReached = true;
        return false;
      }

      // Relative stall: value stopped changing (precision exhausted)
      if (_lastValue != null && _lastValue != 0.0) {
        final prev = _lastValue!;
        final rel = ((value - prev).abs()) / prev.abs();
        if (value == prev || rel < 1e-15) {
          _error = 'Precision limit';
          _limitReached = true;
          return false;
        }
      }

      // Hard cap on count
      if (_sequentialDivisions > _maxSequentialDivisions) {
        _error = 'Precision limit';
        _limitReached = true;
        return false;
      }
    } else {
      // Reset division chain if current op not division
      _sequentialDivisions = 0;
    }

    // Integer precision ceiling
    if (intMode && value.abs() > _maxExactInt) {
      _error = 'Precision limit';
      _limitReached = true;
      return false;
    }

    _result = _formatNumber(value, intMode: intMode);
    _lastValue = value;
    return true;
  }

  void _repeatLastOperation() {
    if (_result.isEmpty || _lastOperator.isEmpty || _lastOperand.isEmpty) return;
    final newExpression = '$_result$_lastOperator$_lastOperand';
    final val = _evaluate(newExpression);
    if (val == null) {
      _error = 'Invalid repeat';
      return;
    }
    final intMode = _isPureIntegerExpression(newExpression);
    if (!_finalize(val, intMode: intMode, op: _lastOperator)) return;
  }

  void _evaluateCurrent() {
    if (_expression.isEmpty) return;
    final val = _evaluate(_expression);
    if (val == null) {
      _error = 'Invalid expression';
      _result = '';
      return;
    }
    final intMode = _isPureIntegerExpression(_expression);
    String? opForContext;
    final opMatch = RegExp(r'([+\-×÷])[^+\-×÷]*$').firstMatch(_expression);
    if (opMatch != null) opForContext = opMatch.group(1);
    if (!_finalize(val, intMode: intMode, op: opForContext)) return;
    _storeRepeatData(_expression);
    _expression = '';
  }

  bool _isOperator(String v) => v == '+' || v == '-' || v == '×' || v == '÷';

  void _onPressed(String value) {
    setState(() {
      if (_limitReached && value != 'C') return;
      _error = '';

      if (value == 'C') {
        _expression = '';
        _result = '';
        _lastOperator = '';
        _lastOperand = '';
        _limitReached = false;
        _lastValue = null;
        _sequentialDivisions = 0;
        _monotonicTrend = 0; // reset decreasing-trend tracking
        return;
      }

      if (value == '=') {
        if (_expression.isNotEmpty) {
          _evaluateCurrent();
        } else {
          _repeatLastOperation();
        }
        return;
      }

      if (_isOperator(value)) {
        if (_expression.isEmpty) {
          if (_result.isNotEmpty) {
            _expression = _result + value;
            _result = '';
          }
          return;
        }
        if (_isOperator(_expression.characters.last)) {
          _expression = _expression.substring(0, _expression.length - 1) + value;
        } else {
          _expression += value;
        }
        return;
      }

      // digits / dot
      if (_result.isNotEmpty && _expression.isEmpty) {
        _expression = value;
        _result = '';
        _lastOperator = '';
        _lastOperand = '';
        _lastValue = null;
        _sequentialDivisions = 0;
        _monotonicTrend = 0; // reset when starting a new entry after showing a result
      } else {
        if (value == '.') {
          final parts = _expression.split(RegExp(r'[+\-×÷]'));
          final currentSegment = parts.isEmpty ? '' : parts.last;
          if (currentSegment.contains('.')) return;
        }
        _expression += value;
      }
    });
  }

  Widget _buildButton(String label,
      {Color color = Colors.blue, double fontSize = 24}) {
    final disabled = _limitReached && label != 'C';
    return Expanded(
      child: Padding(
        padding: const EdgeInsets.all(4),
        child: ElevatedButton(
          style: ElevatedButton.styleFrom(
            backgroundColor: disabled ? Colors.grey.shade600 : color,
            foregroundColor: Colors.white,
            padding: const EdgeInsets.symmetric(vertical: 20),
          ),
          onPressed: disabled ? null : () => _onPressed(label),
          child: Text(label, style: TextStyle(fontSize: fontSize)),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Kyle Mard')),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            Container(
              alignment: Alignment.centerRight,
              padding: const EdgeInsets.symmetric(vertical: 24, horizontal: 12),
              child: Text(
                _expression,
                style: const TextStyle(fontSize: 32),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            if (_error.isNotEmpty)
              Text(
                _error,
                style: TextStyle(
                  color: _error.contains('Underflow')
                      ? Colors.orange
                      : Colors.red,
                ),
              ),
            if (_result.isNotEmpty)
              Container(
                alignment: Alignment.centerRight,
                padding: const EdgeInsets.symmetric(horizontal: 12),
                child: Text(
                  _result,
                  style: const TextStyle(
                      fontSize: 36, fontWeight: FontWeight.bold),
                ),
              ),
            const Spacer(),
            Column(
              children: [
                Row(
                  children: [
                    _buildButton('7'),
                    _buildButton('8'),
                    _buildButton('9'),
                    _buildButton('÷', color: Colors.red),
                  ],
                ),
                Row(
                  children: [
                    _buildButton('4'),
                    _buildButton('5'),
                    _buildButton('6'),
                    _buildButton('×', color: Colors.red),
                  ],
                ),
                Row(
                  children: [
                    _buildButton('1'),
                    _buildButton('2'),
                    _buildButton('3'),
                    _buildButton('-', color: Colors.orange),
                  ],
                ),
                Row(
                  children: [
                    _buildButton('0'),
                    _buildButton('.'),
                    _buildButton('C', color: Colors.grey),
                    _buildButton('+', color: Colors.orange),
                  ],
                ),
                Row(
                  children: [
                    _buildButton('=', color: Colors.green, fontSize: 28),
                  ],
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
