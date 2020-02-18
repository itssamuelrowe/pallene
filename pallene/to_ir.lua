-- Copyright (c) 2020, The Pallene Developers
-- Pallene is licensed under the MIT license.
-- Please refer to the LICENSE and AUTHORS files for details
-- SPDX-License-Identifier: MIT

local ir = require "pallene.ir"
local types = require "pallene.types"
local util = require "pallene.util"

local to_ir = {}

local ToIR -- forward declaration

function to_ir.convert(module)
    for _, func in ipairs(module.functions) do
        local cmds = {}
        ToIR.new(module, func):convert_stat(cmds, func.body)
        func.body = ir.Cmd.Seq(cmds)
    end
    ir.clean_all(module)
    return module, {}
end

--
--
--

ToIR = util.Class()
function ToIR:init(module, func)
    self.module = module
    self.func = func
end

function ToIR:convert_stats(cmds, stats)
    for i = 1, #stats do
        self:convert_stat(cmds, stats[i])
    end
end

-- Converts a typechecked ast.Stat into a list of ir.Cmd
-- The converted ir.Cmd nodes are appended to the @cmds list
function ToIR:convert_stat(cmds, stat)
    local tag = stat._tag
    if     tag == "ast.Stat.Block" then
        self:convert_stats(cmds, stat.stats)

    elseif tag == "ast.Stat.While" then
        local body = {}
        local cond     = self:exp_to_value(body, stat.condition)
        local condBool = self:value_is_truthy(body, stat.condition, cond)
        table.insert(body, ir.Cmd.If(stat.loc, condBool, ir.Cmd.Nop(), ir.Cmd.Break()))
        self:convert_stat(body, stat.block)
        table.insert(cmds, ir.Cmd.Loop(ir.Cmd.Seq(body)))

    elseif tag == "ast.Stat.Repeat" then
        local body = {}
        self:convert_stat(body, stat.block)
        local cond     = self:exp_to_value(body, stat.condition)
        local condBool = self:value_is_truthy(body, stat.condition, cond)
        table.insert(body, ir.Cmd.If(stat.loc, condBool, ir.Cmd.Break(), ir.Cmd.Nop()))
        table.insert(cmds, ir.Cmd.Loop(ir.Cmd.Seq(body)))

    elseif tag == "ast.Stat.If" then
        local cond     = self:exp_to_value(cmds, stat.condition)
        local condBool = self:value_is_truthy(cmds, stat.condition, cond)
        local then_ = {}; self:convert_stat(then_, stat.then_)
        local else_ = {}; self:convert_stat(else_, stat.else_)
        table.insert(cmds, ir.Cmd.If(
            stat.loc, condBool,
            ir.Cmd.Seq(then_),
            ir.Cmd.Seq(else_)))

    elseif tag == "ast.Stat.For" then
        local start = self:exp_to_value(cmds, stat.start)
        local limit = self:exp_to_value(cmds, stat.limit)
        local step  = self:exp_to_value(cmds, stat.step)

        local cname = stat.decl._name
        assert(cname._tag == "checker.Name.Local")
        local v = cname.id
        local typ = self.func.vars[v].typ

        local body = {}
        self:convert_stat(body, stat.block)

        table.insert(cmds, ir.Cmd.For(stat.loc,
            typ, v,
            start, limit, step,
            ir.Cmd.Seq(body)))

    elseif tag == "ast.Stat.Assign" then
        local var = assert(#stat.vars == 1 and stat.vars[1])
        local exp = assert(#stat.exps == 1 and stat.exps[1])
        if     var._tag == "ast.Var.Name" then
            local cname = var._name
            if     cname._tag == "checker.Name.Local" then
                self:exp_to_assignment(cmds, cname.id, exp)
            elseif cname._tag == "checker.Name.Global" then
                local v = self:exp_to_value(cmds, exp)
                table.insert(cmds, ir.Cmd.SetGlobal(stat.loc, cname.id, v))
            else
                error("impossible")
            end

        elseif var._tag == "ast.Var.Bracket" then
            local arr = self:exp_to_value(cmds, var.t)
            local i   = self:exp_to_value(cmds, var.k)
            local v   = self:exp_to_value(cmds, exp)
            local src_typ = exp._type
            table.insert(cmds, ir.Cmd.SetArr(stat.loc, src_typ, arr, i, v))

        elseif var._tag == "ast.Var.Dot" then
            local typ = assert(var.exp._type)
            local field = var.name
            local rec = self:exp_to_value(cmds, var.exp)
            local v   = self:exp_to_value(cmds, exp)
            local cmd
            if     typ._tag == "types.T.Table" then
                local key = ir.Value.String(field)
                cmd = ir.Cmd.SetTable(stat.loc, exp._type, rec, key, v)
            elseif typ._tag == "types.T.Record" then
                cmd = ir.Cmd.SetField(stat.loc, typ, rec, field, v)
            else
                error("impossible")
            end
            table.insert(cmds, cmd)

        else
            error("impossible")
        end

    elseif tag == "ast.Stat.Decl" then
        if stat.exps[1] then
            local cname = stat.decls[1]._name
            assert(cname._tag == "checker.Name.Local")
            local v = cname.id
            self:exp_to_assignment(cmds, v, stat.exps[1])
        end

    elseif tag == "ast.Stat.Call" then
        self:exp_to_assignment(cmds, false, stat.call_exp)

    elseif tag == "ast.Stat.Return" then
        for i, exp in ipairs(stat.exps) do
            local dst = ir.ret_var(self.func, i)
            self:exp_to_assignment(cmds, dst, exp)
        end
        table.insert(cmds, ir.Cmd.Return())

    elseif tag == "ast.Stat.Break" then
        table.insert(cmds, ir.Cmd.Break())

    else
        error("impossible")
    end
end

local unops = {
    { "#",   "Array",   "ArrLen"  },
    { "#",   "String",  "StrLen"  },
    { "-",   "Integer", "IntNeg"  },
    { "-",   "Float",   "FltNeg"  },
    { "~",   "Integer", "BitNeg"  },
    { "not", "Boolean", "BoolNot" },
}

local binops = {
    { "+"  , "Integer", "Integer", "IntAdd"  },
    { "-"  , "Integer", "Integer", "IntSub"  },
    { "*"  , "Integer", "Integer", "IntMul"  },
    { "//" , "Integer", "Integer", "IntDivi" },
    { "%"  , "Integer", "Integer", "IntMod"  },

    { "+"  , "Float",   "Float",   "FltAdd"  },
    { "-"  , "Float",   "Float",   "FltSub"  },
    { "*"  , "Float",   "Float",   "FltMul"  },
    { "//" , "Float",   "Float",   "FltDivi" },
    { "%"  , "Float",   "Float",   "FltMod"  },
    { "/"  , "Float",   "Float",   "FltDiv"  },

    { "&" , "Integer", "Integer", "BitAnd"    },
    { "|" , "Integer", "Integer", "BitOr"     },
    { "~" , "Integer", "Integer", "BitXor"    },
    { "<<", "Integer", "Integer", "BitLShift" },
    { ">>", "Integer", "Integer", "BitRShift" },

    { "^" , "Float",   "Float",   "FltPow" },

    { "==", "Any",   "Any",   "AnyEq"  },
    { "~=", "Any",   "Any",   "AnyNeq" },

    { "==", "Nil",     "Nil",     "NilEq"  },
    { "~=", "Nil",     "Nil",     "NilNeq" },

    { "==", "Boolean", "Boolean", "BoolEq"  },
    { "~=", "Boolean", "Boolean", "BoolNeq" },

    { "==", "Integer", "Integer", "IntEq"  },
    { "~=", "Integer", "Integer", "IntNeq" },
    { "<" , "Integer", "Integer", "IntLt"  },
    { ">" , "Integer", "Integer", "IntGt"  },
    { "<=", "Integer", "Integer", "IntLeq" },
    { ">=", "Integer", "Integer", "IntGeq" },

    { "==", "Float",   "Float",   "FltEq"  },
    { "~=", "Float",   "Float",   "FltNeq" },
    { "<" , "Float",   "Float",   "FltLt"  },
    { ">" , "Float",   "Float",   "FltGt"  },
    { "<=", "Float",   "Float",   "FltLeq" },
    { ">=", "Float",   "Float",   "FltGeq" },

    { "==", "String",  "String",   "StrEq"  },
    { "~=", "String",  "String",   "StrNeq" },
    { "<" , "String",  "String",   "StrLt"  },
    { ">" , "String",  "String",   "StrGt"  },
    { "<=", "String",  "String",   "StrLeq" },
    { ">=", "String",  "String",   "StrGeq" },

    { "==", "Function","Function", "FunctionEq"  },
    { "~=", "Function","Function", "FunctionNeq" },

    { "==", "Array",   "Array",    "ArrayEq"    },
    { "~=", "Array",   "Array",    "ArrayNeq"    },

    { "==", "Table",   "Table",    "TableEq"    },
    { "~=", "Table",   "Table",    "TableNeq"    },

    { "==", "Record",  "Record",   "RecordEq",  },
    { "~=", "Record",  "Record",   "RecordNeq",  },
}

local function type_specific_unop(op, typ)
   for _, x in ipairs(unops) do
        local op_, typ_, name = x[1], x[2], x[3]
        if
            op == op_ and
            typ._tag == ("types.T." .. typ_)
        then
            return name
        end
    end
    error("impossible")
end

local function type_specific_binop(op, typ1, typ2)
    for _, x in ipairs(binops) do
        local op_, typ1_, typ2_, name = x[1], x[2], x[3], x[4]
        if
            op == op_ and
            typ1._tag == ("types.T." .. typ1_) and
            typ2._tag == ("types.T." .. typ2_)
        then
            return name
        end
    end
    error("impossible")
end

-- Converts a typechecked ast.Exp to a ir.Value. If necessary, will create a
-- fresh variable, and add intermediate computations to the @cmds list.
function ToIR:exp_to_value(cmds, exp, _recursive)
    local tag = exp._tag
    if     tag == "ast.Exp.Nil" then
        return ir.Value.Nil()

    elseif tag == "ast.Exp.Bool" then
        return ir.Value.Bool(exp.value)

    elseif tag == "ast.Exp.Integer" then
        return ir.Value.Integer(exp.value)

    elseif tag == "ast.Exp.Float" then
        return ir.Value.Float(exp.value)

    elseif tag == "ast.Exp.String" then
        return ir.Value.String(exp.value)

    elseif tag == "ast.Exp.Var" then
        local var = exp.var
        if     var._tag == "ast.Var.Name" then
            local cname = var._name
            if     cname._tag == "checker.Name.Local" then
                return ir.Value.LocalVar(cname.id)

            elseif cname._tag == "checker.Name.Global" then
                -- Fallthrough to default

            elseif cname._tag == "checker.Name.Function" then
                return ir.Value.Function(cname.id)

            elseif cname._tag == "checker.Name.Builtin" then
                error("not implemented")

            else
                error("impossible")
            end
        else
            -- Fallthrough to default
        end
    end

    if _recursive then
        -- Avoid infinite loop due to type error
        error(string.format(
            "Neither exp_to_value or exp_to_assignment handled tag %q)",
            exp._tag))
    end

    -- Otherwise we need to create a temporary variable
    local v = ir.add_local(self.func, false, exp._type)
    self:exp_to_assignment(cmds, v, exp)
    return ir.Value.LocalVar(v)
end

-- Converts the assignment `dst = exp` into a list of ir.Cmd, which are added
-- to the @cmds list. (If this is a function call, then dst may be false)
function ToIR:exp_to_assignment(cmds, dst, exp)
    local loc = exp.loc
    local tag = exp._tag

    local old_len = #cmds

    if not dst then
        assert(tag == "ast.Exp.CallFunc" or tag == "ast.Exp.CallMethod")
    end

    if     tag == "ast.Exp.Initlist" then
        local typ = exp._type
        if     typ._tag == "types.T.Array" then
            local n = #exp.fields
            table.insert(cmds, ir.Cmd.NewArr(loc, dst, n))
            table.insert(cmds, ir.Cmd.CheckGC())
            for i, field in ipairs(exp.fields) do
                local av = ir.Value.LocalVar(dst)
                local iv = ir.Value.Integer(i)
                local vv = self:exp_to_value(cmds, field.exp)
                local src_typ = field.exp._type
                table.insert(cmds, ir.Cmd.SetArr(loc, src_typ, av, iv, vv))
            end

        elseif typ._tag == "types.T.Table" then
            local n = #exp.fields
            table.insert(cmds, ir.Cmd.NewTable(loc, dst, n))
            table.insert(cmds, ir.Cmd.CheckGC())
            for _, field in ipairs(exp.fields) do
                local tv = ir.Value.LocalVar(dst)
                local kv = ir.Value.String(field.name)
                local vv = self:exp_to_value(cmds, field.exp)
                local src_typ = field.exp._type
                local cmd = ir.Cmd.SetTable(loc, src_typ, tv, kv, vv)
                table.insert(cmds, cmd)
            end

        elseif typ._tag == "types.T.Record" then
            local field_exps = {}
            for _, field in ipairs(exp.fields) do
                field_exps[field.name] = field.exp
            end

            table.insert(cmds, ir.Cmd.NewRecord(loc, typ, dst))
            table.insert(cmds, ir.Cmd.CheckGC())
            for _, field_name in ipairs(typ.field_names) do
                local f_exp = assert(field_exps[field_name])
                local dv = ir.Value.LocalVar(dst)
                local vv = self:exp_to_value(cmds, f_exp)
                table.insert(cmds,
                    ir.Cmd.SetField(exp.loc, typ, dv, field_name, vv))
            end
        else
            error("impossible")
        end

    elseif tag == "ast.Exp.Lambda" then
        error("not implemented")

    elseif tag == "ast.Exp.CallFunc" then

        local function get_xs()
            -- "xs" should be evaluated after "f"
            local xs = {}
            for i, arg_exp in ipairs(exp.args) do
                xs[i] = self:exp_to_value(cmds, arg_exp)
            end
            return xs
        end

        local f_typ = exp.exp._type
        local cname = (
            exp.exp._tag == "ast.Exp.Var" and
            exp.exp.var._tag == "ast.Var.Name" and
            exp.exp.var._name )

        if     cname and cname._tag == "checker.Name.Function" then
            local xs = get_xs()
            table.insert(cmds, ir.Cmd.CallStatic(loc, f_typ, dst, cname.id, xs))

        elseif cname and cname._tag == "checker.Name.Builtin" then
            local xs = get_xs()

            local bname = cname.name
            if     bname == "io_write" then
                assert(#xs == 1)
                table.insert(cmds, ir.Cmd.BuiltinIoWrite(loc, xs[1]))
            elseif bname == "math_sqrt" then
                assert(#xs == 1)
                table.insert(cmds, ir.Cmd.BuiltinMathSqrt(loc, dst, xs[1]))
            elseif bname == "string_char" then
                assert(#xs == 1)
                table.insert(cmds, ir.Cmd.BuiltinStringChar(loc, dst, xs[1]))
                table.insert(cmds, ir.Cmd.CheckGC())
            elseif bname == "string_sub" then
                assert(#xs == 3)
                table.insert(cmds,
                    ir.Cmd.BuiltinStringSub(loc, dst, xs[1], xs[2], xs[3]))
                table.insert(cmds, ir.Cmd.CheckGC())

            elseif bname == "tofloat" then
                assert(#xs == 1)
                table.insert(cmds, ir.Cmd.BuiltinToFloat(loc, dst, xs[1]))
            else
                error("impossible")
            end

        else
            local f = self:exp_to_value(cmds, exp.exp)
            local xs = get_xs()
            table.insert(cmds, ir.Cmd.CallDyn(loc, f_typ, dst, f, xs))
        end

    elseif tag == "ast.Exp.CallMethod" then
        error("not implemented")

    elseif tag == "ast.Exp.Var" then
        local var = exp.var
        if     var._tag == "ast.Var.Name" then
            local cname = var._name
            if cname._tag == "checker.Name.Global" then
                table.insert(cmds, ir.Cmd.GetGlobal(loc, dst, cname.id))
            else
                -- Falthrough to default
            end

        elseif var._tag == "ast.Var.Bracket" then
            local arr = self:exp_to_value(cmds, var.t)
            local i   = self:exp_to_value(cmds, var.k)
            local dst_typ = var._type
            table.insert(cmds, ir.Cmd.GetArr(loc, dst_typ, dst, arr, i))

        elseif var._tag == "ast.Var.Dot" then
            local typ = assert(var.exp._type)
            local field = var.name
            local rec = self:exp_to_value(cmds, var.exp)
            local cmd
            if     typ._tag == "types.T.Table" then
                local key = ir.Value.String(field)
                local dst_typ = typ.fields[field]
                cmd = ir.Cmd.GetTable(loc, dst_typ, dst, rec, key)
            elseif typ._tag == "types.T.Record" then
                cmd = ir.Cmd.GetField(loc, typ, dst, rec, field)
            else
                error("impossible")
            end
            table.insert(cmds, cmd)

        else
            error("impossible")
        end

    elseif tag == "ast.Exp.Unop" then
        local op = exp.op
        if op == "not" then
            local e = self:exp_to_value(cmds, exp.exp)
            local v = self:value_is_truthy(cmds, exp.exp, e)
            table.insert(cmds, ir.Cmd.Unop(loc, dst, "BoolNot", v))
        else
            local irop = type_specific_unop(op, exp.exp._type)
            local v = self:exp_to_value(cmds, exp.exp)
            table.insert(cmds, ir.Cmd.Unop(loc, dst, irop, v))
        end

    elseif tag == "ast.Exp.Concat" then
        local xs = {}
        for i, x_exp in ipairs(exp.exps) do
            xs[i] = self:exp_to_value(cmds, x_exp)
        end
        table.insert(cmds, ir.Cmd.Concat(loc, dst, xs))
        table.insert(cmds, ir.Cmd.CheckGC())

    elseif tag == "ast.Exp.Binop" then
        local op = exp.op
        if     op == "and" then
            self:exp_to_assignment(cmds, dst, exp.lhs)
            local v = ir.Value.LocalVar(dst)
            local condBool = self:value_is_truthy(cmds, exp.lhs, v)
            local rhs_cmds = {}
            self:exp_to_assignment(rhs_cmds, dst, exp.rhs)
            table.insert(cmds, ir.Cmd.If(exp.loc,
                condBool,
                ir.Cmd.Seq(rhs_cmds),
                ir.Cmd.Seq({})))

        elseif op == "or" then
            self:exp_to_assignment(cmds, dst, exp.lhs)
            local v = ir.Value.LocalVar(dst)
            local condBool = self:value_is_truthy(cmds, exp.lhs, v)
            local rhs_cmds = {}
            self:exp_to_assignment(rhs_cmds, dst, exp.rhs)
            table.insert(cmds, ir.Cmd.If(exp.loc,
                condBool,
                ir.Cmd.Seq({}),
                ir.Cmd.Seq(rhs_cmds)))

        else
            local irop =
                type_specific_binop(op, exp.lhs._type, exp.rhs._type)
            local v1 = self:exp_to_value(cmds, exp.lhs)
            local v2 = self:exp_to_value(cmds, exp.rhs)
            table.insert(cmds, ir.Cmd.Binop(loc, dst, irop, v1, v2))
        end

    elseif tag == "ast.Exp.Cast" then
        local dst_typ = exp._type
        local src_typ = exp.exp._type
        if src_typ._tag == dst_typ._tag then
            -- Do-nothing cast
            self:exp_to_assignment(cmds, dst, exp.exp)
        else
            local v = self:exp_to_value(cmds, exp.exp)
            if     dst_typ._tag == "types.T.Any" then
                table.insert(cmds, ir.Cmd.ToDyn(loc, src_typ, dst, v))
            elseif src_typ._tag == "types.T.Any" then
                table.insert(cmds, ir.Cmd.FromDyn(loc, dst_typ, dst, v))
            else
                error("impossible")
            end
        end
    end

    if old_len == #cmds then
        -- If we haven't added any new Cmds by now it means that we fell
        -- through to the default case.
        local value = self:exp_to_value(cmds, exp, true)
        table.insert(cmds, ir.Cmd.Move(loc, dst, value))
    end
end

-- Returns a boolean value corresponding to whether exp is truthy.
-- As usual, may add intermediate cmds to the @cmds list
function ToIR:value_is_truthy(cmds, exp, val)
    local typ = exp._type
    if typ._tag == "types.T.Boolean" then
        return val
    elseif typ._tag == "types.T.Any" then
        local b = ir.add_local(self.func, false, types.T.Boolean())
        table.insert(cmds, ir.Cmd.IsTruthy(exp.loc, b, val))
        return ir.Value.LocalVar(b)
    else
        error("impossible")
    end
end

return to_ir
