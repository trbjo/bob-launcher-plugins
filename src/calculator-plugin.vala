[ModuleInit]
public Type plugin_init(TypeModule type_module) {
    return typeof(BobLauncher.CalculatorPlugin);
}


namespace BobLauncher {
    namespace Mather {
        private class MathFuncWrapper {
            public delegate double MathFunc(double x);
            public MathFunc func { get; owned set; }

            public MathFuncWrapper(owned MathFunc func) {
                this.func = (owned) func;
            }

            public double call(double x) {
                return func(x);
            }
        }

        public class MathParser : Object {
            private static HashTable<string, double?> constants;
            private static HashTable<string, MathFuncWrapper> functions;

            static construct {
                constants = new HashTable<string, double?>(str_hash, str_equal);
                constants["pi"] = Math.PI;
                constants["e"] = Math.E;

                functions = new HashTable<string, MathFuncWrapper>(str_hash, str_equal);
                functions["sin"] = new MathFuncWrapper((x) => Math.sin(x));
                functions["cos"] = new MathFuncWrapper((x) => Math.cos(x));
                functions["tan"] = new MathFuncWrapper((x) => Math.tan(x));
                functions["asin"] = new MathFuncWrapper((x) => Math.asin(x));
                functions["acos"] = new MathFuncWrapper((x) => Math.acos(x));
                functions["atan"] = new MathFuncWrapper((x) => Math.atan(x));
                functions["sqrt"] = new MathFuncWrapper((x) => Math.sqrt(x));
                functions["ln"] = new MathFuncWrapper((x) => Math.log(x));
                functions["logten"] = new MathFuncWrapper((x) => Math.log10(x));
                functions["log"] = new MathFuncWrapper((x) => Math.log2(x));
                functions["exp"] = new MathFuncWrapper((x) => Math.exp(x));
                functions["abs"] = new MathFuncWrapper((x) => Math.fabs(x));
            }

            public double parse(string expr) throws Error {
                string expression = expr.down().replace(" ", "");
                int position = 0;
                return parse_expression(expression, ref position);
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
                double left = parse_power(expression, ref position);

                while (position < expression.length) {
                    char op = expression[position];
                    if (op != '*' && op != '/') break;
                    position++;

                    double right = parse_power(expression, ref position);
                    if (op == '*') left *= right;
                    else {
                        if (right == 0) throw new Error.DIVISION_BY_ZERO("Division by zero");
                        left /= right;
                    }
                }

                return left;
            }

            private double parse_power(string expression, ref int position) throws Error {
                double left = parse_factor(expression, ref position);

                while (position < expression.length - 1) {  // Length - 1 to check for two-character operators
                    char op = expression[position];
                    if (op != '^' && op != '<' && op != '>') break;

                    if (op == '^') {
                        position++;
                        double right = parse_factor(expression, ref position);
                        left = Math.pow(left, right);
                    } else if (op == '<' || op == '>') {
                        if (expression[position + 1] != op) break;  // Ensure it's '<<' or '>>'
                        position += 2;
                        double right = parse_factor(expression, ref position);
                        int shift = (int)right;
                        if (op == '<') {
                            left = (double)((long)left << shift);
                        } else {
                            left = (double)((long)left >> shift);
                        }
                    }
                }

                return left;
            }


            private double parse_factor(string expression, ref int position) throws Error {
                if (position >= expression.length) throw new Error.UNEXPECTED_END("Unexpected end of expression");

                char c = expression[position];
                if (c == '(') {
                    position++;
                    double result = parse_expression(expression, ref position);
                    if (position >= expression.length || expression[position] != ')')
                        throw new Error.MISMATCHED_PARENTHESES("Mismatched parentheses");
                    position++;
                    return result;
                } else if (c == '-') {
                    position++;
                    return -parse_factor(expression, ref position);
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
                while (position < expression.length && (expression[position].isdigit() || expression[position] == '.')) {
                    position++;
                }
                string num_str = expression[start:position];
                return double.parse(num_str);
            }

            private double parse_identifier(string expression, ref int position) throws Error {
                int start = position;
                while (position < expression.length && expression[position].isalpha()) {
                    position++;
                }
                string identifier = expression[start:position];

                if (constants.contains(identifier)) {
                    double? value = constants[identifier];
                    if (value == null) {
                        throw new Error.UNKNOWN_IDENTIFIER("Null value for identifier: %s", identifier);
                    }
                    return value;
                } else if (functions.contains(identifier)) {
                    if (position >= expression.length || expression[position] != '(')
                        throw new Error.INVALID_FUNCTION("Expected '(' after function name");
                    position++;
                    double arg = parse_expression(expression, ref position);
                    if (position >= expression.length || expression[position] != ')')
                        throw new Error.MISMATCHED_PARENTHESES("Expected ')' after function argument");
                    position++;
                    return functions[identifier].call(arg);
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
        private CalcResult calc_match;
        private static Mather.MathParser math_parser;

        static construct {
            math_parser = new Mather.MathParser();
        }

        public CalculatorPlugin(GLib.TypeModule module) {
            Object();
        }

        construct {
            icon_name = "accessories-calculator";
            calc_match = new CalcResult();
        }

        private class CalcResult : Match, ITextMatch {
            private static string _result;

            static construct {
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
                return "Calculator";
            }

            public void set_result(double result) {
                _result = "%g".printf(result);
            }
        }

        private CalcResult get_calc_match() {
            return this.calc_match;
        }

        public override void search(ResultContainer rs) {
            string input = rs.get_query().replace(",", ".").replace("=", "");
            try {
                double result = math_parser.parse(input);
                this.calc_match.set_result(result);
                rs.add_lazy_unique(MatchScore.HIGHEST + bonus, get_calc_match);
            } catch (Error e) {
                debug("Error evaluating expression: %s", e.message);
                this.calc_match.set_result(0);
            }
        }
    }
}
