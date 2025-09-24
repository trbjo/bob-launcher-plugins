[ModuleInit]
public Type plugin_init(TypeModule type_module) {
    return typeof(BobLauncher.CalculatorPlugin);
}


namespace BobLauncher {
    namespace Mather {
        public class MathParser : Object {
            private static HashTable<string, double?> constants;

            static construct {
                constants = new HashTable<string, double?>(str_hash, str_equal);
                constants["pi"] = Math.PI;
                constants["phi"] = 1.618033988749895;
                constants["e"] = Math.E;

                // Integer limit constants - all are case-insensitive due to .down() in parse()
                // Users can type: int16.max, INT16.MAX, Int16.Max, INT16_MAX, etc.

                // Add C-style naming conventions with underscores
                constants["int8_max"] = int8.MAX;
                constants["int8_min"] = int8.MIN;
                constants["uint8_max"] = uint8.MAX;
                constants["int16_max"] = int16.MAX;
                constants["int16_min"] = int16.MIN;
                constants["uint16_max"] = uint16.MAX;
                constants["int32_max"] = int32.MAX;
                constants["int32_min"] = int32.MIN;
                constants["uint32_max"] = uint32.MAX;
                constants["int64_max"] = int64.MAX;
                constants["int64_min"] = int64.MIN;
                constants["uint64_max"] = uint64.MAX;

                // Also support common C limits.h names
                constants["char_max"] = int8.MAX;
                constants["char_min"] = int8.MIN;
                constants["uchar_max"] = uint8.MAX;
                constants["schar_max"] = int8.MAX;
                constants["schar_min"] = int8.MIN;
                constants["shrt_max"] = int16.MAX;
                constants["shrt_min"] = int16.MIN;
                constants["ushrt_max"] = uint16.MAX;
                constants["int_max"] = int32.MAX;
                constants["int_min"] = int32.MIN;
                constants["uint_max"] = uint32.MAX;
                constants["long_max"] = int64.MAX;
                constants["long_min"] = int64.MIN;
                constants["ulong_max"] = uint64.MAX;
            }

            public double parse(string expr) throws Error {
                int position = 0;
                return parse_or(expr, ref position);
            }

            private bool is_function(string name) {
                switch (name) {
                    case "sin":
                    case "cos":
                    case "tan":
                    case "asin":
                    case "acos":
                    case "atan":
                    case "sqrt":
                    case "ln":
                    case "logten":
                    case "log":
                    case "exp":
                    case "abs":
                        return true;
                    default:
                        return false;
                }
            }

            private double run_function(string func, double arg) throws Error {
                switch (func) {
                    case "sin":
                        return Math.sin(arg);
                    case "cos":
                        return Math.cos(arg);
                    case "tan":
                        return Math.tan(arg);
                    case "asin":
                        return Math.asin(arg);
                    case "acos":
                        return Math.acos(arg);
                    case "atan":
                        return Math.atan(arg);
                    case "sqrt":
                        return Math.sqrt(arg);
                    case "ln":
                        return Math.log(arg);
                    case "logten":
                        return Math.log10(arg);
                    case "log":
                        return Math.log2(arg);
                    case "exp":
                        return Math.exp(arg);
                    case "abs":
                        return Math.fabs(arg);
                    default:
                        throw new Error.UNKNOWN_IDENTIFIER("Unknown function: %s", func);
                }
            }

            // Lowest precedence: OR
            private double parse_or(string expression, ref int position) throws Error {
                double left = parse_xor(expression, ref position);

                while (position < expression.length) {
                    char op = expression[position];
                    if (op != '|') break;

                    // Check if it's || (logical OR) or | (bitwise OR)
                    if (position + 1 < expression.length && expression[position + 1] == '|') {
                        position += 2;
                        double right = parse_xor(expression, ref position);
                        left = ((long)left != 0 || (long)right != 0) ? 1.0 : 0.0;
                    } else {
                        position++;
                        double right = parse_xor(expression, ref position);
                        left = (double)((long)left | (long)right);
                    }
                }
                return left;
            }

            // XOR precedence
            private double parse_xor(string expression, ref int position) throws Error {
                double left = parse_and(expression, ref position);

                while (position < expression.length) {
                    char op = expression[position];
                    if (op != '^') break;
                    position++;

                    double right = parse_and(expression, ref position);
                    left = (double)((long)left ^ (long)right);
                }
                return left;
            }

            // AND precedence
            private double parse_and(string expression, ref int position) throws Error {
                double left = parse_expression(expression, ref position);

                while (position < expression.length) {
                    char op = expression[position];
                    if (op != '&') break;

                    // Check if it's && (logical AND) or & (bitwise AND)
                    if (position + 1 < expression.length && expression[position + 1] == '&') {
                        position += 2;
                        double right = parse_expression(expression, ref position);
                        left = ((long)left != 0 && (long)right != 0) ? 1.0 : 0.0;
                    } else {
                        position++;
                        double right = parse_expression(expression, ref position);
                        left = (double)((long)left & (long)right);
                    }
                }
                return left;
            }

            private double parse_expression(string expression, ref int position) throws Error {
                double left = parse_term(expression, ref position);

                while (position < expression.length) {
                    char op = expression[position];
                    if (op != '+' && op != '-') break;
                    position++;

                    double right = parse_term(expression, ref position);
                    if (op == '+') left += right;
                    else left -= right;
                }
                return left;
            }

            private double parse_term(string expression, ref int position) throws Error {
                double left = parse_shift(expression, ref position);

                while (position < expression.length) {
                    char op = expression[position];
                    if (op != '*' && op != '/' && op != '%') break;
                    position++;

                    double right = parse_shift(expression, ref position);
                    if (op == '*') {
                        left *= right;
                    } else if (op == '/') {
                        if (right == 0) throw new Error.DIVISION_BY_ZERO("Division by zero");
                        left /= right;
                    } else { // modulo
                        if (right == 0) throw new Error.DIVISION_BY_ZERO("Modulo by zero");
                        left = (double)((long)left % (long)right);
                    }
                }

                return left;
            }

            // Shift operators
            private double parse_shift(string expression, ref int position) throws Error {
                double left = parse_power(expression, ref position);

                while (position < expression.length - 1) {
                    char op = expression[position];
                    if (op != '<' && op != '>') break;

                    if (expression[position + 1] != op) break;  // Ensure it's '<<' or '>>'
                    position += 2;
                    double right = parse_power(expression, ref position);
                    int shift = (int)right;
                    if (op == '<') {
                        left = (double)((long)left << shift);
                    } else {
                        left = (double)((long)left >> shift);
                    }
                }

                return left;
            }

            private double parse_power(string expression, ref int position) throws Error {
                double left = parse_unary(expression, ref position);

                while (position < expression.length - 1) {
                    // Check for ** (exponentiation)
                    if (expression[position] == '*' && expression[position + 1] == '*') {
                        position += 2;
                        double right = parse_unary(expression, ref position);
                        left = Math.pow(left, right);
                    } else {
                        break;
                    }
                }

                return left;
            }

            // Unary operators (-, ~)
            private double parse_unary(string expression, ref int position) throws Error {
                if (position >= expression.length) throw new Error.UNEXPECTED_END("Unexpected end of expression");

                char c = expression[position];
                if (c == '-') {
                    position++;
                    return -parse_unary(expression, ref position);
                } else if (c == '~') {
                    position++;
                    return (double)(~(long)parse_unary(expression, ref position));
                } else {
                    return parse_factor(expression, ref position);
                }
            }

            private double parse_factor(string expression, ref int position) throws Error {
                if (position >= expression.length) throw new Error.UNEXPECTED_END("Unexpected end of expression");

                char c = expression[position];
                if (c == '(') {
                    position++;
                    double result = parse_or(expression, ref position);
                    if (position >= expression.length || expression[position] != ')')
                        throw new Error.MISMATCHED_PARENTHESES("Mismatched parentheses");
                    position++;
                    return result;
                } else if (c.isdigit() || c == '.') {
                    return parse_number(expression, ref position);
                } else if (c.isalpha()) {
                    return parse_identifier(expression, ref position);
                } else {
                    throw new Error.INVALID_CHARACTER("Invalid character: %c", c);
                }
            }

            private double parse_number(string expression, ref int position) throws Error {
                int start = position;

                // Check for hex (0x prefix)
                if (position + 1 < expression.length &&
                    expression[position] == '0' &&
                    expression[position + 1] == 'x') {
                    position += 2;
                    start = position;
                    while (position < expression.length &&
                           (expression[position].isxdigit())) {
                        position++;
                    }
                    string hex_str = expression[start:position];
                    return (double)long.parse("0x" + hex_str, 16);
                }

                // Check for binary (0b prefix)
                if (position + 1 < expression.length &&
                    expression[position] == '0' &&
                    expression[position + 1] == 'b') {
                    position += 2;
                    start = position;
                    while (position < expression.length &&
                           (expression[position] == '0' || expression[position] == '1')) {
                        position++;
                    }
                    string bin_str = expression[start:position];
                    long val = 0;
                    for (int i = 0; i < bin_str.length; i++) {
                        val = (val << 1) | (bin_str[i] == '1' ? 1 : 0);
                    }
                    return (double)val;
                }

                // Regular decimal number
                while (position < expression.length &&
                       (expression[position].isdigit() || expression[position] == '.')) {
                    position++;
                }
                string num_str = expression[start:position];
                return double.parse(num_str);
            }

            private double parse_identifier(string expression, ref int position) throws Error {
                int start = position;
                // Allow alphanumeric, dots, and underscores for constants like int16.max or INT16_MAX
                while (position < expression.length &&
                       (expression[position].isalnum() ||
                        expression[position] == '.' ||
                        expression[position] == '_')) {
                    position++;
                }
                string identifier = expression[start:position];

                if (constants.contains(identifier)) {
                    return constants[identifier];
                } else if (is_function(identifier)) {
                    if (position >= expression.length || expression[position] != '(')
                        throw new Error.INVALID_FUNCTION("Expected '(' after function name");
                    position++;
                    double arg = parse_or(expression, ref position);
                    if (position >= expression.length || expression[position] != ')')
                        throw new Error.MISMATCHED_PARENTHESES("Expected ')' after function argument");
                    position++;
                    return run_function(identifier, arg);
                } else {
                    throw new Error.UNKNOWN_IDENTIFIER("Unknown identifier: %s", identifier);
                }
            }
        }

        public errordomain Error {
            INVALID_EXPRESSION,
            DIVISION_BY_ZERO,
            UNEXPECTED_END,
            MISMATCHED_PARENTHESES,
            INVALID_CHARACTER,
            INVALID_FUNCTION,
            UNKNOWN_IDENTIFIER
        }
    }

    public class CalculatorPlugin : SearchBase {
        private CalcResult calc_match_decimal;
        private CalcResult calc_match_hex;
        private CalcResult calc_match_binary;
        private CalcResult calc_match_fraction;
        private CalcResult calc_match_properties;
        private static Mather.MathParser math_parser;

        static construct {
            math_parser = new Mather.MathParser();
        }

        public CalculatorPlugin(GLib.TypeModule module) {
            Object();
        }

        construct {
            icon_name = "accessories-calculator";
            calc_match_decimal = new CalcResult("Decimal");
            calc_match_hex = new CalcResult("Hexadecimal");
            calc_match_binary = new CalcResult("Binary");
            calc_match_fraction = new CalcResult("Simplified Fraction");
            calc_match_properties = new CalcResult("Special Properties");
        }

        private class CalcResult : Match, ITextMatch {
            private string _result;
            private string _format_name;

            public CalcResult(string format_name) {
                _format_name = format_name;
                _result = "0";
            }

            public override string get_icon_name() {
                return "accessories-calculator";
            }

            public string get_text() {
                return _result;
            }

            public override string get_title() {
                return _result;
            }

            public override string get_description() {
                return "Calculator - " + _format_name;
            }

            public void set_result(string result) {
                _result = result;
            }
        }

        private CalcResult get_calc_match_decimal() {
            return this.calc_match_decimal;
        }

        private CalcResult get_calc_match_hex() {
            return this.calc_match_hex;
        }

        private CalcResult get_calc_match_binary() {
            return this.calc_match_binary;
        }

        private CalcResult get_calc_match_fraction() {
            return this.calc_match_fraction;
        }

        private CalcResult get_calc_match_properties() {
            return this.calc_match_properties;
        }

        private bool is_prime(long n) {
            if (n <= 1) return false;
            if (n <= 3) return true;
            if (n % 2 == 0 || n % 3 == 0) return false;

            long i = 5;
            while (i * i <= n) {
                if (n % i == 0 || n % (i + 2) == 0) return false;
                i += 6;
            }
            return true;
        }

        private bool is_perfect_square(long n) {
            if (n < 0) return false;
            long root = (long)Math.sqrt((double)n);
            return root * root == n;
        }

        private bool is_power_of_two(long n) {
            if (n <= 0) return false;
            return (n & (n - 1)) == 0;
        }

        private bool is_fibonacci(long n) {
            if (n < 0) return false;
            // A number is Fibonacci if one of (5*n^2 + 4) or (5*n^2 - 4) is a perfect square
            long test1 = 5 * n * n + 4;
            long test2 = 5 * n * n - 4;
            return is_perfect_square(test1) || is_perfect_square(test2);
        }

        private long factorial(long n) {
            if (n <= 1) return 1;
            long result = 1;
            for (long i = 2; i <= n; i++) {
                result *= i;
                if (result < 0) return -1; // Overflow
            }
            return result;
        }

        private string get_special_properties(double value) {
            // Only analyze integers
            if (value != Math.floor(value)) return "";

            long n = (long)value;
            string[] properties = {};

            // Check for common integer limits
            if (n == int8.MAX) properties += "int8_t max";
            else if (n == int8.MIN) properties += "int8_t min";
            else if (n == uint8.MAX) properties += "uint8_t max";
            else if (n == int16.MAX) properties += "int16_t max";
            else if (n == int16.MIN) properties += "int16_t min";
            else if (n == uint16.MAX) properties += "uint16_t max";
            else if (n == int32.MAX) properties += "int32_t max";
            else if (n == int32.MIN) properties += "int32_t min";
            else if (value == (double)uint32.MAX) properties += "uint32_t max";
            else if (value == (double)int64.MAX) properties += "int64_t max";
            else if (value == (double)int64.MIN) properties += "int64_t min";
            else if (value == (double)uint64.MAX) properties += "uint64_t max";

            // Check mathematical properties
            if (n > 0) {
                if (is_prime(n)) properties += "prime";
                if (is_power_of_two(n)) {
                    int power = 0;
                    long temp = n;
                    while (temp > 1) {
                        temp /= 2;
                        power++;
                    }
                    properties += "2^%d".printf(power);
                }
                if (is_perfect_square(n)) {
                    properties += "√%ld = %ld".printf(n, (long)Math.sqrt((double)n));
                }
                if (is_fibonacci(n)) properties += "Fibonacci";

                // Check if it's a factorial
                for (int i = 2; i <= 20; i++) {
                    if (factorial(i) == n) {
                        properties += "%d!".printf(i);
                        break;
                    }
                }

                // Check for powers of 10
                if (n == 10 || n == 100 || n == 1000 || n == 10000 ||
                    n == 100000 || n == 1000000 || n == 10000000) {
                    int zeros = 0;
                    long temp = n;
                    while (temp > 1) {
                        temp /= 10;
                        zeros++;
                    }
                    properties += "10^%d".printf(zeros);
                }

                // Perfect numbers
                if (n == 6 || n == 28 || n == 496 || n == 8128) {
                    properties += "perfect number";
                }
            }

            // Special numbers
            if (n == 0) properties += "zero";
            if (n == 1) properties += "unity";
            if (n == 42) properties += "answer to life";
            if (n == 1337) properties += "leet";
            if (n == 404) properties += "not found";
            if (n == 666) properties += "number of the beast";
            if (n == 420) properties += "nice";
            if (n == 69) properties += "nice";

            if (properties.length == 0) return "";
            return string.joinv(", ", properties);
        }

        private long gcd(long a, long b) {
            a = a.abs();
            b = b.abs();
            while (b != 0) {
                long temp = b;
                b = a % b;
                a = temp;
            }
            return a;
        }

        private bool try_get_fraction(double value, out long numerator, out long denominator) {
            numerator = 0;
            denominator = 1;

            // Handle negative numbers
            bool negative = value < 0;
            value = Math.fabs(value);

            // Limit precision to avoid huge fractions from floating point errors
            double tolerance = 1e-10;
            long max_denominator = 10000;

            // Special case for integers
            if (Math.fabs(value - Math.round(value)) < tolerance) {
                numerator = (long)Math.round(value);
                denominator = 1;
                if (negative) numerator = -numerator;
                return true;
            }

            // Use continued fractions algorithm to find best rational approximation
            long n0 = 0, d0 = 1;
            long n1 = 1, d1 = 0;
            double fraction = value;

            for (int i = 0; i < 20; i++) {  // Limit iterations
                long a = (long)Math.floor(fraction);
                long n2 = n0 + a * n1;
                long d2 = d0 + a * d1;

                if (d2 > max_denominator) break;

                n0 = n1; n1 = n2;
                d0 = d1; d1 = d2;

                double error = Math.fabs(value - (double)n2 / d2);
                if (error < tolerance) {
                    numerator = n2;
                    denominator = d2;
                    if (negative) numerator = -numerator;
                    return true;
                }

                fraction = fraction - a;
                if (fraction < tolerance) break;
                fraction = 1.0 / fraction;
            }

            // Use the last valid approximation
            if (d1 > 0 && d1 <= max_denominator) {
                numerator = n1;
                denominator = d1;
                if (negative) numerator = -numerator;
                return true;
            }

            return false;
        }

        public override void search(ResultContainer rs) {
            string input = rs.get_query().down().replace(" ", "").replace(".min", "_min").replace(".max", "_max").replace(",", ".").replace("=", "");
            try {
                double result = math_parser.parse(input);

                // Check if input contains decimal point (after comma replacement)
                bool input_has_decimal = input.contains(".");

                // Set decimal result - format based on whether input had decimals
                string decimal_str;
                if (result == Math.floor(result) && !input_has_decimal) {
                    // Integer result and no decimals in input - show as integer
                    decimal_str = "%.0f".printf(result);
                } else {
                    // Either non-integer result or input had decimals
                    // Use 10 decimal places for reasonable precision without floating point noise
                    decimal_str = "%.10f".printf(result);
                    // Trim trailing zeros after decimal point
                    while (decimal_str.contains(".") && decimal_str.has_suffix("0")) {
                        decimal_str = decimal_str.substring(0, decimal_str.length - 1);
                    }
                    // If we trimmed all decimals, add back .0 if input had decimals
                    if (decimal_str.has_suffix(".")) {
                        if (input_has_decimal) {
                            decimal_str = decimal_str + "0";
                        } else {
                            decimal_str = decimal_str.substring(0, decimal_str.length - 1);
                        }
                    }
                }
                this.calc_match_decimal.set_result(decimal_str);
                rs.add_lazy_unique(0, get_calc_match_decimal);

                // Try to express as a simplified fraction
                long numerator, denominator;
                if (try_get_fraction(result, out numerator, out denominator)) {
                    // Simplify the fraction
                    long divisor = gcd(numerator, denominator);
                    numerator /= divisor;
                    denominator /= divisor;

                    // Only show fraction if it's different from just the integer
                    // and the denominator is reasonable (not 1, not too large)
                    if (denominator > 1 && denominator <= 1000) {
                        string fraction_str = "%ld/%ld".printf(numerator, denominator);
                        this.calc_match_fraction.set_result(fraction_str);
                        rs.add_lazy_unique(0, get_calc_match_fraction);
                    }
                }

                // For integer results, also show hex and binary
                long int_result = (long)result;
                if (result == (double)int_result) {
                    // Set hexadecimal result
                    this.calc_match_hex.set_result("0x%lX".printf(int_result));
                    rs.add_lazy_unique(0, get_calc_match_hex);

                    // Set binary result
                    string binary = "";
                    if (int_result == 0) {
                        binary = "0b0";
                    } else {
                        long temp = int_result;
                        string bits = "";
                        bool negative = temp < 0;
                        if (negative) temp = -temp;

                        while (temp > 0) {
                            bits = (temp % 2 == 1 ? "1" : "0") + bits;
                            temp /= 2;
                        }
                        binary = (negative ? "-" : "") + "0b" + bits;
                    }
                    this.calc_match_binary.set_result(binary);
                    rs.add_lazy_unique(0, get_calc_match_binary);
                }

                // Check for special properties
                string properties = get_special_properties(result);
                if (properties != "") {
                    this.calc_match_properties.set_result(properties);
                    rs.add_lazy_unique(0, get_calc_match_properties);
                }
            } catch (Error e) {
                debug("Error evaluating expression: %s", e.message);
                this.calc_match_decimal.set_result("0");
                this.calc_match_hex.set_result("0x0");
                this.calc_match_binary.set_result("0b0");
                this.calc_match_fraction.set_result("");
                this.calc_match_properties.set_result("");
            }
        }
    }
}
