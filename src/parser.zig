const std = @import("std");
const builtin = @import("builtin");
const stdx = @import("stdx");
const t = stdx.testing;
const fatal = cy.fatal;
const fmt = @import("fmt.zig");
const v = fmt.v;
const cy = @import("cyber.zig");
const Token = cy.tokenizer.Token;

const NodeId = cy.NodeId;
const TokenId = u32;
const log = cy.log.scoped(.parser);
const IndexSlice = cy.IndexSlice(u32);

const dumpParseErrorStackTrace = !cy.isFreestanding and builtin.mode == .Debug and !cy.isWasm and true;

const dirModifiers = std.ComptimeStringMap(cy.ast.DirModifierType, .{
    .{ "host", .host },
});

const Block = struct {
    vars: std.StringHashMapUnmanaged(void),

    fn deinit(self: *Block, alloc: std.mem.Allocator) void {
        self.vars.deinit(alloc);
    }
};

const ParseOptions = struct {
    parseComments: bool = false,
};

/// Parses source code into AST.
pub const Parser = struct {
    alloc: std.mem.Allocator,

    /// Context vars.
    next_pos: u32,
    savePos: u32,

    ast: cy.ast.Ast,
    tokens: []const Token,

    last_err: []const u8,
    /// The last error's src char pos.
    last_err_pos: u32,
    blockStack: std.ArrayListUnmanaged(Block),
    cur_indent: u32,

    /// Use the parser pass to record static declarations.
    staticDecls: std.ArrayListUnmanaged(StaticDecl),

    // TODO: This should be implemented by user callbacks.
    /// @name arg.
    name: []const u8,
    /// Variable dependencies.
    deps: std.StringHashMapUnmanaged(NodeId),

    inObjectDecl: bool,

    /// For custom functions.
    user: struct {
        ctx: *anyopaque,
        advanceChar: *const fn (*anyopaque) void,
        peekChar: *const fn (*anyopaque) u8,
        peekCharAhead: *const fn (*anyopaque, u32) ?u8,
        isAtEndChar: *const fn (*anyopaque) bool,
        getSubStrFromDelta: *const fn (*anyopaque, u32) []const u8,
        savePos: *const fn (*anyopaque) void,
        restorePos: *const fn (*anyopaque) void,
    },

    pub fn init(alloc: std.mem.Allocator) !Parser {
        return .{
            .alloc = alloc,
            .ast = try cy.ast.Ast.init(alloc, ""),
            .next_pos = undefined,
            .savePos = undefined,
            .tokens = undefined,
            .last_err = "",
            .last_err_pos = 0,
            .blockStack = .{},
            .cur_indent = 0,
            .name = "",
            .deps = .{},
            .user = undefined,
            .staticDecls = .{},
            .inObjectDecl = false,
        };
    }

    pub fn deinit(self: *Parser) void {
        self.ast.deinit(self.alloc);
        self.alloc.free(self.last_err);
        for (self.blockStack.items) |*block| {
            block.deinit(self.alloc);
        }
        self.blockStack.deinit(self.alloc);
        self.deps.deinit(self.alloc);
        self.staticDecls.deinit(self.alloc);
    }

    fn dumpTokensToCurrent(self: *Parser) void {
        for (self.tokens[0..self.next_pos+1]) |token| {
            log.tracev("{}", .{token.tag()});
        }
    }

    pub fn parseNoErr(self: *Parser, src: []const u8, opts: ParseOptions) !ResultView {
        const res = try self.parse(src, opts);
        if (res.has_error) {
            log.tracev("{s}", .{res.err_msg});
            return error.ParseError;
        }
        return res;
    }

    pub fn parse(self: *Parser, src: []const u8, opts: ParseOptions) !ResultView {
        self.ast.src = src;
        self.name = "";
        self.deps.clearRetainingCapacity();

        var tokenizer = cy.Tokenizer.init(self.alloc, src);
        defer tokenizer.deinit();

        tokenizer.parseComments = opts.parseComments;
        try tokenizer.tokens.ensureTotalCapacityPrecise(self.alloc, 511);
        tokenizer.tokenize() catch |err| {
            log.tracev("tokenize error: {}", .{err});
            if (dumpParseErrorStackTrace and !cy.silentError) {
                std.debug.dumpStackTrace(@errorReturnTrace().?.*);
            }
            self.last_err = tokenizer.consumeErr();
            self.last_err_pos = tokenizer.lastErrPos;
            return ResultView{
                .has_error = true,
                .isTokenError = true,
                .err_msg = self.last_err,
                .root_id = cy.NullNode,
                .ast = self.ast.view(),
                .name = self.name,
                .deps = &self.deps,
            };
        };
        self.ast.comments = tokenizer.consumeComments();
        self.tokens = tokenizer.tokens.items;

        const root_id = self.parseRoot() catch |err| {
            log.tracev("parse error: {} {s}", .{err, self.last_err});
            // self.dumpTokensToCurrent();
            logSrcPos(self.ast.src, self.last_err_pos, 20);
            if (dumpParseErrorStackTrace and !cy.silentError) {
                std.debug.dumpStackTrace(@errorReturnTrace().?.*);
            }
            return ResultView{
                .has_error = true,
                .isTokenError = false,
                .err_msg = self.last_err,
                .root_id = cy.NullNode,
                .ast = self.ast.view(),
                .name = self.name,
                .deps = &self.deps,
            };
        };
        return ResultView{
            .has_error = false,
            .isTokenError = false,
            .err_msg = "",
            .root_id = root_id,
            .ast = self.ast.view(),
            .name = self.name,
            .deps = &self.deps,
        };
    }

    fn parseRoot(self: *Parser) !NodeId {
        self.next_pos = 0;
        try self.ast.nodes.ensureTotalCapacityPrecise(self.alloc, 127);
        try self.ast.clearNodes(self.alloc);
        self.blockStack.clearRetainingCapacity();
        self.cur_indent = 0;

        const root_id = try self.ast.pushNode(self.alloc, .root, 0);

        const indent = (try self.consumeIndentBeforeStmt()) orelse {
            self.ast.setNodeData(root_id, .{ .root = .{
                .bodyHead = cy.NullNode,
            }});
            return root_id;
        };
        if (indent != 0) {
            return self.reportError("Unexpected indentation.", &.{});
        }

        try self.pushBlock();
        const res = try self.parseBodyStatements(0);

        // Mark last expression stmt.
        const last = self.ast.nodePtr(res.last);
        if (last.type() == .exprStmt) {
            last.data.exprStmt.isLastRootStmt = true;
        }

        const block = self.popBlock();
        _ = block;

        self.ast.setNodeData(root_id, .{ .root = .{
            .bodyHead = res.first,
        }});
        return root_id;
    }

    /// Returns number of spaces that precedes a statement.
    /// The current line is consumed if there is no statement.
    fn consumeIndentBeforeStmt(self: *Parser) !?u32 {
        while (true) {
            // Spaces, count = 0.
            var res: u32 = 0;
            var token = self.peek();
            if (token.tag() == .indent) {
                res = token.data.indent;
                self.advance();
                token = self.peek();
            }
            if (token.tag() == .new_line) {
                self.advance();
                continue;
            } else if (token.tag() == .indent) {
                // If another indent token is encountered, it would be a different type.
                return self.reportError("Can not mix tabs and spaces for indentation.", &.{});
            } else if (token.tag() == .none) {
                return null;
            } else {
                return res;
            }
        }
    }

    fn pushBlock(self: *Parser) !void {
        try self.blockStack.append(self.alloc, .{
            .vars = .{},
        });
    }

    fn popBlock(self: *Parser) Block {
        var block = self.blockStack.pop();
        block.deinit(self.alloc);
        return block;
    }

    fn parseSingleOrIndentedBodyStmts(self: *Parser) !FirstLastStmt {
        var token = self.peek();
        if (token.tag() != .new_line) {
            // Parse single statement only.
            const stmt = try self.parseStatement();
            return .{
                .first = stmt,
                .last = stmt,
            };
        } else {
            self.advance();
            return self.parseIndentedBodyStatements();
        }
    }

    /// Indent is determined by the first body statement.
    fn parseIndentedBodyStatements(self: *Parser) !FirstLastStmt {
        const reqIndent = try self.parseFirstChildIndent(self.cur_indent);
        return self.parseBodyStatements(reqIndent);
    }

    // Assumes the first indent is already consumed.
    fn parseBodyStatements(self: *Parser, reqIndent: u32) !FirstLastStmt {
        const prevIndent = self.cur_indent;
        self.cur_indent = reqIndent;
        defer self.cur_indent = prevIndent;

        var first = try self.parseStatement();
        var last = first;

        // Parse body statements until indentation goes back to at least the previous indent.
        while (true) {
            const start = self.next_pos;
            const indent = (try self.consumeIndentBeforeStmt()) orelse break;
            if (indent == reqIndent) {
                const id = try self.parseStatement();
                self.ast.setNextNode(last, id);
                last = id;
            } else if (try isRecedingIndent(self, prevIndent, reqIndent, indent)) {
                self.next_pos = start;
                break;
            } else {
                return self.reportError("Unexpected indentation.", &.{});
            }
        }
        return .{
            .first = first,
            .last = last,
        };
    }

    /// Parses the first child indent and returns the indent size.
    fn parseFirstChildIndent(self: *Parser, fromIndent: u32) !u32 {
        const indent = (try self.consumeIndentBeforeStmt()) orelse {
            return self.reportError("Block requires an indented child statement. Use the `pass` statement as a placeholder.", &.{});
        };
        if ((fromIndent ^ indent < 0x80000000) or fromIndent == 0) {
            // Either same indent style or indenting from root.
            if (indent > fromIndent) {
                return indent;
            } else {
                return self.reportError("Block requires an indented child statement. Use the `pass` statement as a placeholder.", &.{});
            }
        } else {
            if (fromIndent & 0x80000000 == 0x80000000) {
                return self.reportError("Expected tabs for indentation.", &.{});
            } else {
                return self.reportError("Expected spaces for indentation.", &.{});
            }
        }
    }

    fn parseLambdaFuncWithParam(self: *Parser, paramIdent: NodeId) !NodeId {
        const start = self.next_pos;
        // Assumes first token is `=>`.
        self.advance();
        
        const id = try self.pushNode(.lambda_expr, start);

        // Parse body expr.
        try self.pushBlock();
        const expr = (try self.parseExpr(.{})) orelse {
            return self.reportError("Expected lambda body expression.", &.{});
        };
        const block = self.popBlock();
        _ = block;

        const identPos = self.ast.nodePos(paramIdent);
        const param = try self.ast.pushNode(self.alloc, .funcParam, identPos);
        self.ast.setNodeData(param, .{ .funcParam = .{
            .name = paramIdent,
            .typeSpec = cy.NullNode,
        }});

        const ret = cy.NullNode;
        const header = try self.ast.pushNode(self.alloc, .funcHeader, ret);
        self.ast.setNodeData(header, .{ .funcHeader = .{
            .name = cy.NullNode,
            .paramHead = param,
        }});

        self.ast.setNodeData(id, .{ .func = .{
            .header = header,
            .bodyHead = expr,
        }});
        return id;
    }

    fn parseNoParamLambdaFunc(self: *Parser) !NodeId {
        const start = self.next_pos;
        // Assumes first token is `=>`.
        self.advance();

        const id = try self.pushNode(.lambda_expr, start);

        // Parse body expr.
        try self.pushBlock();
        const expr = (try self.parseExpr(.{})) orelse {
            return self.reportError("Expected lambda body expression.", &.{});
        };
        _ = self.popBlock();
        
        const ret = cy.NullNode;
        const header = try self.ast.pushNode(self.alloc, .funcHeader, ret);
        self.ast.setNodeData(header, .{ .funcHeader = .{
            .name = cy.NullNode,
            .paramHead = cy.NullNode,
        }});

        self.ast.setNodeData(id, .{ .func = .{
            .header = header,
            .bodyHead = expr,
        }});
        return id;
    }

    fn parseMultilineLambdaFunction(self: *Parser) !NodeId {
        const start = self.next_pos;

        // Assume first token is `func`.
        self.advance();

        const params = try self.parseFuncParams();
        const ret = try self.parseFuncReturn();

        if (self.peek().tag() == .colon) {
            self.advance();
        } else {
            return self.reportError("Expected colon.", &.{});
        }

        const id = try self.pushNode(.lambda_multi, start);

        try self.pushBlock();
        const res = try self.parseSingleOrIndentedBodyStmts();
        _ = self.popBlock();

        const header = try self.ast.pushNode(self.alloc, .funcHeader, ret orelse cy.NullNode);
        self.ast.setNodeData(header, .{ .funcHeader = .{
            .name = cy.NullNode,
            .paramHead = params.head,
        }});

        self.ast.setNodeData(id, .{ .func = .{
            .header = header,
            .bodyHead = res.first,
        }});
        return id;
    }

    fn parseLambdaFunction(self: *Parser) !NodeId {
        const start = self.next_pos;

        const params = try self.parseFuncParams();
        const ret = try self.parseFuncReturn();

        var token = self.peek();
        if (token.tag() != .equal_greater) {
            return self.reportError("Expected =>.", &.{});
        }
        self.advance();

        const id = try self.pushNode(.lambda_expr, start);

        // Parse body expr.
        try self.pushBlock();
        const expr = (try self.parseExpr(.{})) orelse {
            return self.reportError("Expected lambda body expression.", &.{});
        };
        const block = self.popBlock();
        _ = block;

        const header = try self.ast.pushNode(self.alloc, .funcHeader, ret orelse cy.NullNode);
        self.ast.setNodeData(header, .{ .funcHeader = .{
            .name = cy.NullNode,
            .paramHead = params.head,
        }});
        
        self.ast.setNodeData(id, .{ .func = .{
            .header = header,
            .bodyHead = expr,
        }});
        return id;
    }

    const ListResult = struct {
        head: cy.NodeId,
        len: u32,
    };

    fn parseFuncParams(self: *Parser) !ListResult {
        var token = self.peek();
        if (token.tag() != .left_paren) {
            return self.reportError("Expected open parenthesis.", &.{});
        }
        self.advance();

        // Parse params.
        token = self.peek();
        if (token.tag() == .ident) {
            var start = self.next_pos;
            var name = try self.pushSpanNode(.ident, start);

            self.advance();
            var typeSpec = (try self.parseOptTypeSpec(false)) orelse cy.NullNode;

            const paramHead = try self.pushNode(.funcParam, start);
            self.ast.setNodeData(paramHead, .{ .funcParam = .{
                .name = name,
                .typeSpec = typeSpec,
            }});

            var numParams: u32 = 1;
            var last = paramHead;
            while (true) {
                token = self.peek();
                switch (token.tag()) {
                    .comma => {
                        self.advance();
                    },
                    .right_paren => {
                        self.advance();
                        break;
                    },
                    else => return self.reportError("Unexpected token {} in function param list.", &.{v(token.tag())}),
                }

                token = self.peek();
                start = self.next_pos;
                if (token.tag() != .ident and token.tag() != .type_k) {
                    return self.reportError("Expected param identifier.", &.{});
                }

                name = try self.pushSpanNode(.ident, start);
                self.advance();

                typeSpec = (try self.parseOptTypeSpec(false)) orelse cy.NullNode;

                const param = try self.pushNode(.funcParam, start);
                self.ast.setNodeData(param, .{ .funcParam = .{
                    .name = name,
                    .typeSpec = typeSpec,
                }});
                self.ast.setNextNode(last, param);
                numParams += 1;
                last = param;
            }
            return ListResult{
                .head = paramHead,
                .len = numParams,
            };
        } else if (token.tag() == .right_paren) {
            self.advance();
            return ListResult{
                .head = cy.NullNode,
                .len = 0,
            };
        } else return self.reportError("Unexpected token in function param list.", &.{});
    }

    fn parseFuncReturn(self: *Parser) !?NodeId {
        return self.parseOptNamePath();
    }

    fn parseOptName(self: *Parser) !?NodeId {
        const start = self.next_pos;
        var token = self.peek();
        if (token.tag() == .ident) {
            self.advance();
            return try self.pushSpanNode(.ident, start);
        } else if (token.tag() == .none_k) {
            self.advance();
            return try self.pushSpanNode(.ident, start);
        } else if (token.tag() == .error_k) {
            self.advance();
            return try self.pushSpanNode(.ident, start);
        } else if (token.tag() == .type_k) {
            self.advance();
            return try self.pushSpanNode(.ident, start);
        } else if (token.tag() == .enum_k) {
            self.advance();
            return try self.pushSpanNode(.ident, start);
        } else if (token.tag() == .string) {
            self.advance();
            return try self.pushSpanNode(.stringLit, start);
        }
        return null;
    }

    fn parseOptNamePath(self: *Parser) !?NodeId {
        const first = (try self.parseOptName()) orelse {
            return null;
        };

        var token = self.peek();
        if (token.tag() != .dot) {
            return first;
        }
        
        var last = first;
        while (token.tag() == .dot) {
            self.advance();
            const name = (try self.parseOptName()) orelse {
                return self.reportError("Expected name.", &.{});
            };
            self.ast.setNextNode(last, name);
            last = name;
            token = self.peek();
        }
        return first;
    }

    fn parseEnumMember(self: *Parser) !NodeId {
        const start = self.next_pos;
        if (self.peek().tag() != .case_k) {
            return self.reportError("Expected case keyword.", &.{});
        }
        self.advance();

        const name = (try self.parseOptName()) orelse {
            return self.reportError("Expected member identifier.", &.{});
        };

        var typeSpec: cy.NodeId = cy.NullNode;
        const token = self.peek();
        if (token.tag() != .new_line and token.tag() != .none) {
            if (try self.parseOptTypeSpec(true)) |res| {
                typeSpec = res;
            }
        } else {
            try self.consumeNewLineOrEnd();
        }

        const field = try self.pushNode(.enumMember, start);
        self.ast.setNodeData(field, .{ .enumMember = .{
            .name = name,
            .typeSpec = typeSpec,
        }});
        return field;
    }

    fn parseObjectField(self: *Parser) !?NodeId {
        const start = self.next_pos;

        var token = self.peek();
        if (token.tag() != .var_k and token.tag() != .my_k) {
            return null;
        }
        const typed = token.tag() == .var_k;
        self.advance();

        const name = (try self.parseOptName()) orelse {
            return self.reportError("Expected field identifier.", &.{});
        };

        var typeSpec: cy.NodeId = cy.NullNode;
        if (typed) {
            if (try self.parseOptTypeSpec(true)) |node| {
                if (self.ast.nodeType(node) != .objectDecl) {
                    try self.consumeNewLineOrEnd();
                }
                typeSpec = node;
            }
        }

        const field = try self.pushNode(.objectField, start);
        self.ast.setNodeData(field, .{ .objectField = .{
            .name = name,
            .typeSpec = @intCast(typeSpec),
            .typed = typed,
        }});
        return field;
    }

    fn parseTypeDecl(self: *Parser, modifierHead: cy.NodeId) !NodeId {
        const start = self.next_pos;
        // Assumes first token is the `type` keyword.
        self.advance();

        // Parse name.
        const name = (try self.parseOptName()) orelse {
            return self.reportError("Expected type name identifier.", &.{});
        };

        var token = self.peek();
        switch (token.tag()) {
            .enum_k => {
                return self.parseEnumDecl(start, name);
            },
            // `object` is optional.
            .object_k,
            .new_line,
            .colon => {
                return self.parseObjectDecl(start, name, modifierHead);
            },
            else => {
                return self.parseTypeAliasDecl(start, name);
            }
        }
    }

    fn parseOptTypeSpec(self: *Parser, allowUnnamedType: bool) !?NodeId {
        const token = self.peek();
        switch (token.tag()) {
            .comma, 
            .equal,
            .right_paren,
            .new_line,
            .none => {
                return null;
            },
            .object_k => {
                if (allowUnnamedType) {
                    const decl = try self.parseObjectDecl(token.pos(), null, cy.NullNode);
                    try self.staticDecls.append(self.alloc, .{
                        .declT = .object,
                        .nodeId = decl,
                        .data = undefined,
                    });
                    return decl;
                } else {
                    return self.reportError("Unnamed type is not allowed in this context.", &.{});
                }
            },
            else => {
                return try self.parseTermExpr();
            },
        }
    }

    fn parseTypeAliasDecl(self: *Parser, start: TokenId, name: NodeId) !NodeId {
        const typeSpec = (try self.parseOptTypeSpec(false)) orelse {
            return self.reportError("Expected type specifier.", &.{});
        };

        const id = try self.pushNode(.typeAliasDecl, start);
        self.ast.setNodeData(id, .{ .typeAliasDecl = .{
            .name = name,
            .typeSpec = typeSpec,
        }});

        try self.staticDecls.append(self.alloc, .{
            .declT = .typeAlias,
            .nodeId = id,
            .data = undefined,
        });

        return id;
    }

    fn parseEnumDecl(self: *Parser, start: TokenId, name: NodeId) !NodeId {
        // Assumes first token is the `enum` keyword.
        self.advance();

        var token = self.peek();
        if (token.tag() == .colon) {
            self.advance();
        } else {
            return self.reportError("Expected colon.", &.{});
        }

        const reqIndent = try self.parseFirstChildIndent(self.cur_indent);
        const prevIndent = self.cur_indent;
        self.cur_indent = reqIndent;
        defer self.cur_indent = prevIndent;

        var firstMember = try self.parseEnumMember();
        var lastMember = firstMember;
        var numMembers: u32 = 1;
        var isChoiceType = false;

        while (true) {
            const start2 = self.next_pos;
            const indent = (try self.consumeIndentBeforeStmt()) orelse break;
            if (indent == reqIndent) {
                const id = try self.parseEnumMember();
                if (!isChoiceType) {
                    const member = self.ast.nodePtr(id);
                    if (member.data.enumMember.typeSpec != cy.NullNode) {
                        isChoiceType = true;
                    }
                }
                self.ast.setNextNode(lastMember, id);
                lastMember = id;
                numMembers += 1;
            } else if (try isRecedingIndent(self, prevIndent, reqIndent, indent)) {
                self.next_pos = start2;
                break;
            } else {
                return self.reportError("Unexpected indentation.", &.{});
            }
        }
        const id = try self.pushNode(.enumDecl, start);
        self.ast.setNodeData(id, .{ .enumDecl = .{
            .name = @intCast(name),
            .memberHead = @intCast(firstMember),
            .numMembers = @intCast(numMembers),
            .isChoiceType = isChoiceType,
        }});
        try self.staticDecls.append(self.alloc, .{
            .declT = .enumT,
            .nodeId = id,
            .data = undefined,
        });
        return id;
    }

    fn pushObjectDecl(self: *Parser, start: TokenId, nameOpt: ?NodeId, modifierHead: NodeId, fieldsHead: NodeId, numFields: u32, funcsHead: NodeId) !NodeId {
        const id = try self.pushNode(.objectDecl, start);

        const header = try self.pushNode(.objectHeader, start);
        if (nameOpt) |name| {
            self.ast.setNodeData(header, .{ .objectHeader = .{
                .name = @intCast(name),
                .fieldHead = @intCast(fieldsHead),
                .unnamed = false,
                .numFields = @intCast(numFields),
            }});
        } else {
            self.ast.setNodeData(header, .{ .objectHeader = .{
                .name = cy.NullNode,
                .fieldHead = @intCast(fieldsHead),
                .unnamed = true,
                .numFields = @intCast(numFields),
            }});
        }
        self.ast.nodePtr(header).head.data = .{ .objectHeader = .{ .modHead = @intCast(modifierHead) }};

        self.ast.setNodeData(id, .{ .objectDecl = .{
            .header = header,
            .funcHead = funcsHead,
        }});

        try self.staticDecls.append(self.alloc, .{
            .declT = .object,
            .nodeId = id,
            .data = undefined,
        });
        return id;
    }

    fn parseObjectDecl(self: *Parser, start: TokenId, name: ?NodeId, modifierHead: cy.NodeId) anyerror!NodeId {
        self.inObjectDecl = true;
        defer self.inObjectDecl = false;

        var token = self.peek();
        if (token.tag() == .object_k) {
            self.advance();
        }

        token = self.peek();
        if (token.tag() == .colon) {
            self.advance();
        } else {
            // Only declaration. No members.
            return self.pushObjectDecl(start, name, modifierHead, cy.NullNode, 0, cy.NullNode);
        }

        const reqIndent = try self.parseFirstChildIndent(self.cur_indent);
        const prevIndent = self.cur_indent;
        self.cur_indent = reqIndent;
        defer self.cur_indent = prevIndent;

        var numFields: u32 = 0;
        var firstField = (try self.parseObjectField()) orelse cy.NullNode;
        if (firstField != cy.NullNode) {
            numFields += 1;
            var lastField = firstField;

            while (true) {
                const start2 = self.next_pos;
                const indent = (try self.consumeIndentBeforeStmt()) orelse {
                    return self.pushObjectDecl(start, name, modifierHead, firstField, numFields, cy.NullNode);
                };
                if (indent == reqIndent) {
                    const id = (try self.parseObjectField()) orelse break;
                    numFields += 1;
                    self.ast.setNextNode(lastField, id);
                    lastField = id;
                } else if (try isRecedingIndent(self, prevIndent, reqIndent, indent)) {
                    self.next_pos = start2;
                    return self.pushObjectDecl(start, name, modifierHead, firstField, numFields, cy.NullNode);
                } else {
                    return self.reportError("Unexpected indentation.", &.{});
                }
            }
        }

        token = self.peek();
        const firstFunc = try self.parseStatement();
        var nodeT = self.ast.nodeType(firstFunc);
        if (nodeT == .funcDecl) {
            var lastFunc = firstFunc;

            while (true) {
                const start2 = self.next_pos;
                const indent = (try self.consumeIndentBeforeStmt()) orelse break;
                if (indent == reqIndent) {
                    token = self.peek();
                    const func = try self.parseStatement();
                    nodeT = self.ast.nodeType(func);
                    if (nodeT == .funcDecl) {
                        self.ast.setNextNode(lastFunc, func);
                        lastFunc = func;
                    } else return self.reportError("Expected function.", &.{});
                } else if (try isRecedingIndent(self, prevIndent, reqIndent, indent)) {
                    self.next_pos = start2;
                    break;
                } else {
                    return self.reportError("Unexpected indentation.", &.{});
                }
            }
            return self.pushObjectDecl(start, name, modifierHead, firstField, numFields, firstFunc);
        } else {
            return self.reportErrorAtSrc("Expected function.", &.{}, self.ast.nodePos(firstFunc));
        }
    }

    fn parseFuncDecl(self: *Parser, modifierHead: cy.NodeId) !NodeId {
        const start = self.next_pos;
        // Assumes first token is the `func` keyword.
        self.advance();

        // Parse function name.
        const name = (try self.parseOptNamePath()) orelse {
            return self.reportError("Expected function name identifier.", &.{});
        };

        var token = self.peek();
        if (token.tag() == .left_paren) {
            const params = try self.parseFuncParams();
            const ret = try self.parseFuncReturn();

            const nameN = self.ast.nodePtr(name);
            const nameStr = self.ast.nodeString(nameN.*);
            const block = &self.blockStack.items[self.blockStack.items.len-1];
            try block.vars.put(self.alloc, nameStr, {});

            token = self.peek();
            if (token.tag() == .colon) {
                self.advance();

                try self.pushBlock();
                const res = try self.parseSingleOrIndentedBodyStmts();
                _ = self.popBlock();

                const header = try self.ast.pushNode(self.alloc, .funcHeader, ret orelse cy.NullNode);
                self.ast.setNodeData(header, .{ .funcHeader = .{
                    .name = name,
                    .paramHead = params.head,
                }});
                self.ast.nodePtr(header).head.data = .{ .funcHeader = .{ .modHead = @intCast(modifierHead) }};

                const id = try self.pushNode(.funcDecl, start);
                self.ast.setNodeData(id, .{ .func = .{
                    .header = header,
                    .bodyHead = res.first,
                }});

                if (!self.inObjectDecl) {
                    try self.staticDecls.append(self.alloc, .{
                        .declT = .func,
                        .nodeId = id,
                        .data = undefined,
                    });
                }
                return id;
            } else {
                // Just a declaration, no body.
                const header = try self.ast.pushNode(self.alloc, .funcHeader, ret orelse cy.NullNode);
                self.ast.setNodeData(header, .{ .funcHeader = .{
                    .name = name,
                    .paramHead = params.head,
                }});
                self.ast.nodePtr(header).head.data = .{ .funcHeader = .{ .modHead = @intCast(modifierHead) }};

                const id = try self.pushNode(.funcDecl, start);
                self.ast.setNodeData(id, .{ .func = .{
                    .header = header,
                    .bodyHead = cy.NullNode,
                }});

                if (!self.inObjectDecl) {
                    try self.staticDecls.append(self.alloc, .{
                        .declT = .funcInit,
                        .nodeId = id,
                        .data = undefined,
                    });
                }
                return id;
            }
        } else {
            return self.reportError("Expected left paren.", &.{});
        }
    }

    fn parseElseStmt(self: *Parser, outNumElseBlocks: *u32) anyerror!NodeId {
        const save = self.next_pos;
        const indent = try self.consumeIndentBeforeStmt();
        if (indent != self.cur_indent) {
            self.next_pos = save;
            return cy.NullNode;
        }

        var token = self.peek();
        if (token.tag() != .else_k) {
            self.next_pos = save;
            return cy.NullNode;
        }

        const elseBlock = try self.pushNode(.elseBlock, self.next_pos);
        outNumElseBlocks.* += 1;
        self.advance();

        token = self.peek();
        if (token.tag() == .colon) {
            // else block.
            self.advance();

            const res = try self.parseSingleOrIndentedBodyStmts();
            self.ast.setNodeData(elseBlock, .{ .elseBlock = .{
                .bodyHead = res.first,
                .cond = cy.NullNode,
            }});
            return elseBlock;
        } else {
            // else if block.
            const cond = (try self.parseExpr(.{})) orelse {
                return self.reportError("Expected else if condition.", &.{});
            };
            token = self.peek();
            if (token.tag() == .colon) {
                self.advance();

                const res = try self.parseSingleOrIndentedBodyStmts();
                self.ast.setNodeData(elseBlock, .{ .elseBlock = .{
                    .bodyHead = res.first,
                    .cond = cond,
                }});

                const nested_else = try self.parseElseStmt(outNumElseBlocks);
                if (nested_else != cy.NullNode) {
                    self.ast.setNextNode(elseBlock, nested_else);
                }
                return elseBlock;
            } else {
                return self.reportError("Expected colon after else if condition.", &.{});
            }
        }
    }

    fn consumeStmtIndentTo(self: *Parser, reqIndent: u32) !void {
        const indent = (try self.consumeIndentBeforeStmt()) orelse {
            return self.reportError("Expected statement.", &.{});
        };
        if (reqIndent != indent) {
            return self.reportError("Unexpected statement indentation.", &.{});
        }
    }

    fn tryConsumeStmtIndentTo(self: *Parser, reqIndent: u32) !bool {
        const save = self.next_pos;
        const indent = (try self.consumeIndentBeforeStmt()) orelse return false;
        if (reqIndent != indent) {
            self.next_pos = save;
            return false;
        }
        return true;
    }

    fn parseSwitch(self: *Parser, isStmt: bool) !NodeId {
        const start = self.next_pos;
        // Assumes first token is the `switch` keyword.
        self.advance();

        const expr = (try self.parseExpr(.{})) orelse {
            return self.reportError("Expected switch expression.", &.{});
        };

        var caseIndent = self.cur_indent;
        var isBlock = false;
        if (self.peek().tag() == .colon) {
            isBlock = true;
            self.advance();
            caseIndent = try self.parseFirstChildIndent(self.cur_indent);
        } else if (self.peek().tag() == .new_line) {
            try self.consumeStmtIndentTo(caseIndent);
        } else {
            return self.reportError("Expected colon after switch condition.", &.{});
        }

        var firstCase = (try self.parseCaseBlock()) orelse {
            return self.reportError("Expected case or else block.", &.{});
        };
        var lastCase = firstCase;
        var numCases: u32 = 1;

        // Parse body statements until no more case blocks indentation recedes.
        while (true) {
            const save = self.next_pos;
            if (!try self.tryConsumeStmtIndentTo(caseIndent)) {
                break;
            }
            const case = (try self.parseCaseBlock()) orelse {
                if (isBlock) {
                    return self.reportError("Expected case or else block.", &.{});
                }
                // Restore so that next statement outside switch can be parsed.
                self.next_pos = save;
                break;
            };
            numCases += 1;
            self.ast.setNextNode(lastCase, case);
            lastCase = case;
        }

        const nodet: cy.NodeType = if (isStmt) .switchStmt else .switchExpr;
        const switchBlock = try self.pushNode(nodet, start);
        self.ast.setNodeData(switchBlock, .{ .switchBlock = .{
            .expr = expr,
            .caseHead = @intCast(firstCase),
            .numCases = @intCast(numCases),
        }});
        return switchBlock;
    }

    fn parseTryStmt(self: *Parser) !NodeId {
        const start = self.next_pos;
        // Assumes first tokens are `try` and `:`.
        self.advance();
        self.advance();

        const stmt = try self.pushNode(.tryStmt, start);

        const tryStmts = try self.parseSingleOrIndentedBodyStmts();

        const indent = try self.consumeIndentBeforeStmt();
        if (indent != self.cur_indent) {
            return self.reportError("Expected catch block.", &.{});
        }

        var token = self.peek();
        if (token.tag() != .catch_k) {
            return self.reportError("Expected catch block.", &.{});
        }
        const catchStmt = try self.pushNode(.catchStmt, self.next_pos);
        self.advance();

        token = self.peek();
        var errorVar: NodeId = cy.NullNode;
        if (token.tag() == .ident) {
            errorVar = try self.pushSpanNode(.ident, self.next_pos);
            self.advance();
        }

        token = self.peek();
        if (token.tag() != .colon) {
            return self.reportError("Expected colon.", &.{});
        }
        self.advance();

        const catchBody = try self.parseSingleOrIndentedBodyStmts();

        self.ast.setNodeData(catchStmt, .{ .catchStmt = .{
            .errorVar = errorVar,
            .bodyHead = catchBody.first,
        }});

        self.ast.setNodeData(stmt, .{ .tryStmt = .{
            .bodyHead = tryStmts.first,
            .catchStmt = catchStmt,
        }});
        return stmt;
    }

    fn parseIfStatement(self: *Parser) !NodeId {
        const start = self.next_pos;
        // Assumes first token is the `if` keyword.
        self.advance();

        const cond = (try self.parseExpr(.{})) orelse {
            return self.reportError("Expected if condition.", &.{});
        };

        var token = self.peek();
        if (token.tag() != .colon) {
            return self.reportError("Expected colon after if condition.", &.{});
        }
        self.advance();

        const ifStmt = try self.pushNode(.ifStmt, start);

        var res = try self.parseSingleOrIndentedBodyStmts();

        var numElseBlocks: u32 = 0;
        const elseBlock = try self.parseElseStmt(&numElseBlocks);

        const ifBranch = try self.pushNode(.ifBranch, start);
        self.ast.setNodeData(ifBranch, .{ .ifBranch = .{
            .cond = cond,
            .bodyHead = res.first,
        }});

        self.ast.setNodeData(ifStmt, .{ .ifStmt = .{
            .ifBranch = ifBranch,
            .elseHead = @intCast(elseBlock),
            .numElseBlocks = @intCast(numElseBlocks),
        }});
        return ifStmt;
    }

    fn parseImportStmt(self: *Parser) !NodeId {
        const start = self.next_pos;
        // Assumes first token is the `import` keyword.
        self.advance();

        var token = self.peek();
        if (token.tag() == .ident) {
            const ident = try self.pushSpanNode(.ident, self.next_pos);
            self.advance();

            token = self.peek();
            var spec: cy.NodeId = cy.NullNode;
            if (token.tag() != .new_line) {
                spec = (try self.parseExpr(.{})) orelse {
                    return self.reportError("Expected import specifier.", &.{});
                };
                const spec_t = self.ast.nodeType(spec);
                if (spec_t == .stringLit) {
                    try self.consumeNewLineOrEnd();
                } else {
                    return self.reportError("Expected import specifier to be a string. {}", &.{fmt.v(spec_t)});
                }
            } else {
                self.advance();
            }

            const import = try self.pushNode(.importStmt, start);
            self.ast.setNodeData(import, .{ .importStmt = .{
                .name = ident,
                .spec = spec,
            }});

            try self.staticDecls.append(self.alloc, .{
                .declT = .import,
                .nodeId = import,
                .data = undefined,
            });
            return import;
        } else {
            return self.reportError("Expected import clause.", &.{});
        }
    }

    fn parseWhileStatement(self: *Parser) !NodeId {
        const start = self.next_pos;
        // Assumes first token is the `while` keyword.
        self.advance();

        var token = self.peek();
        if (token.tag() == .colon) {
            self.advance();

            // Infinite loop.
            const res = try self.parseSingleOrIndentedBodyStmts();

            const whileStmt = try self.pushNode(.whileInfStmt, start);
            self.ast.setNodeData(whileStmt, .{ .whileInfStmt = .{
                .bodyHead = res.first,
            }});
            return whileStmt;
        }

        // Parse next token as expression.
        const expr_id = (try self.parseExpr(.{})) orelse {
            return self.reportError("Expected condition expression.", &.{});
        };

        token = self.peek();
        if (token.tag() == .colon) {
            self.advance();
            const res = try self.parseSingleOrIndentedBodyStmts();

            const whileStmt = try self.pushNode(.whileCondStmt, start);
            self.ast.setNodeData(whileStmt, .{ .whileCondStmt = .{
                .cond = expr_id,
                .bodyHead = res.first,
            }});
            return whileStmt;
        } else if (token.tag() == .capture) {
            self.advance();
            token = self.peek();
            const ident = (try self.parseExpr(.{})) orelse {
                return self.reportError("Expected ident.", &.{});
            };
            if (self.ast.nodeType(ident) != .ident) {
                return self.reportError("Expected ident.", &.{});
            }
            token = self.peek();
            if (token.tag() != .colon) {
                return self.reportError("Expected :.", &.{});
            }
            self.advance();
            const res = try self.parseSingleOrIndentedBodyStmts();

            const whileStmt = try self.pushNode(.whileOptStmt, start);
            const header = try self.pushNode(.whileOptHeader, start);
            self.ast.setNodeData(header, .{ .whileOptHeader = .{
                .opt = expr_id,
                .capture = ident,
            }});
            self.ast.setNodeData(whileStmt, .{ .whileOptStmt = .{
                .header = header,
                .bodyHead = res.first,
            }});
            return whileStmt;
        } else {
            return self.reportError("Expected :.", &.{});
        }
    }

    fn parseForStatement(self: *Parser) !NodeId {
        const start = self.next_pos;
        // Assumes first token is the `for` keyword.
        self.advance();

        var token = self.peek();
        // Parse next token as expression.
        const expr_pos = self.next_pos;
        const expr_id = (try self.parseExpr(.{})) orelse {
            return self.reportError("Expected condition expression.", &.{});
        };

        token = self.peek();
        if (token.tag() == .colon) {
            self.advance();
            const res = try self.parseSingleOrIndentedBodyStmts();

            const header = try self.pushNode(.forIterHeader, start);
            self.ast.setNodeData(header, .{ .forIterHeader = .{
                .iterable = expr_id,
                .eachClause = cy.NullNode,
            }});
            self.ast.nodePtr(header).head.data = .{ .forIterHeader = .{ .count = cy.NullNode }};

            const forStmt = try self.pushNode(.forIterStmt, start);
            self.ast.setNodeData(forStmt, .{ .forIterStmt = .{
                .header = header,
                .bodyHead = res.first,
            }});
            return forStmt;
        } else if (token.tag() == .dot_dot or token.tag() == .minusDotDot) {
            self.advance();
            const right_range_expr = (try self.parseExpr(.{})) orelse {
                return self.reportError("Expected right range expression.", &.{});
            };
            const header = try self.pushNode(.forRangeHeader, expr_pos);
            self.ast.setNodeData(header, .{ .forRangeHeader = .{
                .start = expr_id,
                .end = @intCast(right_range_expr),
                .increment = token.tag() == .dot_dot,
            }});

            token = self.peek();
            if (token.tag() == .colon) {
                self.advance();

                const res = try self.parseSingleOrIndentedBodyStmts();

                const for_stmt = try self.pushNode(.forRangeStmt, start);
                self.ast.setNodeData(for_stmt, .{ .forRangeStmt = .{
                    .header = header,
                    .bodyHead = res.first,
                }});
                self.ast.nodePtr(header).head.data = .{ .forRangeHeader = .{ .eachClause = cy.NullNode }};
                return for_stmt;
            } else if (token.tag() == .capture) {
                self.advance();

                token = self.peek();
                const ident = (try self.parseExpr(.{})) orelse {
                    return self.reportError("Expected ident.", &.{});
                };
                if (self.ast.nodeType(ident) != .ident) {
                    return self.reportErrorAt("Expected ident.", &.{}, token.pos());
                }
                token = self.peek();
                if (token.tag() != .colon) {
                    return self.reportError("Expected :.", &.{});
                }
                self.advance();

                const res = try self.parseSingleOrIndentedBodyStmts();

                const for_stmt = try self.pushNode(.forRangeStmt, start);
                self.ast.setNodeData(for_stmt, .{ .forRangeStmt = .{
                    .header = header,
                    .bodyHead = res.first,
                }});
                self.ast.nodePtr(header).head.data = .{ .forRangeHeader = .{ .eachClause = @intCast(ident) }};
                return for_stmt;
            } else {
                return self.reportError("Expected :.", &.{});
            }
        } else if (token.tag() == .capture) {
            self.advance();
            token = self.peek();
            var eachClause: NodeId = undefined;
            if (token.tag() == .left_bracket) {
                eachClause = try self.parseSeqDestructure();
            } else {
                eachClause = (try self.parseExpr(.{})) orelse {
                    return self.reportError("Expected each clause.", &.{});
                };
            }

            // Optional count var.
            var count: NodeId = cy.NullNode;
            if (self.peek().tag() == .comma) {
                self.advance();
                count = (try self.parseExpr(.{})) orelse {
                    return self.reportError("Expected count declaration.", &.{});
                };
            }

            if (self.peek().tag() == .colon) {
                self.advance();
            } else {
                return self.reportError("Expected :.", &.{});
            }

            const res = try self.parseSingleOrIndentedBodyStmts();

            const header = try self.pushNode(.forIterHeader, start);
            self.ast.setNodeData(header, .{ .forIterHeader = .{
                .iterable = expr_id,
                .eachClause = eachClause,
            }});
            self.ast.nodePtr(header).head.data = .{ .forIterHeader = .{ .count = @intCast(count) }};

            const forStmt = try self.pushNode(.forIterStmt, start);
            self.ast.setNodeData(forStmt, .{ .forIterStmt = .{
                .header = header,
                .bodyHead = res.first,
            }});
            return forStmt;
        } else {
            return self.reportError("Expected :.", &.{});
        }
    }

    // fn parseBlock(self: *Parser) !NodeId {
    //     const start = self.next_pos;
    //     // Assumes first token is the ident.
    //     const name = try self.pushSpanNode(.ident, start);
    //     self.advance();
    //     // Assumes second token is colon.
    //     self.advance();

    //     // Parse body.
    //     try self.pushBlock();
    //     const res = try self.parseIndentedBodyStatements();
    //     _ = self.popBlock();
        
    //     const id = try self.pushNode(.label_decl, start);
    //     self.nodes.items[id].head = .{
    //         .left_right = .{
    //             .left = name,
    //             .right = res.first,
    //         },
    //     };
    //     return id;
    // }

    fn parseCaseBlock(self: *Parser) !?NodeId {
        const start = self.next_pos;
        var token = self.peek();
        var firstCond: NodeId = undefined;
        var isElse: bool = false;
        var numConds: u32 = 0;
        var bodyExpr: bool = false;
        var capture: u24 = cy.NullNode;
        if (token.tag() == .case_k) {
            self.advance();
            firstCond = (try self.parseTightTermExpr()) orelse {
                return self.reportError("Expected case condition.", &.{});
            };
            numConds += 1;

            var lastCond = firstCond;
            while (true) {
                token = self.peek();
                if (token.tag() == .colon) {
                    self.advance();
                    break;
                } else if (token.tag() == .equal_greater) {
                    self.advance();
                    bodyExpr = true;
                    break;
                } else if (token.tag() == .comma) {
                    self.advance();
                    self.consumeWhitespaceTokens();
                    const cond = (try self.parseTightTermExpr()) orelse {
                        return self.reportError("Expected case condition.", &.{});
                    };
                    self.ast.setNextNode(lastCond, cond);
                    lastCond = cond;
                    numConds += 1;
                } else if (token.tag() == .capture) {
                    self.advance();

                    // Parse next token as expression.
                    capture = @intCast(try self.parseTermExpr());

                    token = self.peek();
                    if (token.tag() == .colon) {
                        self.advance();
                        break;
                    } else if (token.tag() == .equal_greater) {
                        self.advance();
                        bodyExpr = true;
                        break;
                    } else {
                        return self.reportError("Expected comma or colon.", &.{});
                    }
                } else {
                    return self.reportError("Expected comma or colon.", &.{});
                }
            }
        } else if (token.tag() == .else_k) {
            self.advance();
            isElse = true;
            firstCond = cy.NullNode;

            if (self.peek().tag() == .colon) {
                self.advance();
            } else if (self.peek().tag() == .equal_greater) {
                self.advance();
                bodyExpr = true;
            } else {
                return self.reportError("Expected colon or `=>`.", &.{});
            }
        } else return null;

        // Parse body.
        var bodyHead: cy.NodeId = undefined;
        if (bodyExpr) {
            bodyHead = (try self.parseExpr(.{})) orelse {
                return self.reportError("Expected expression.", &.{});
            };
        } else {
            const res = try self.parseSingleOrIndentedBodyStmts();
            bodyHead = res.first;
        }

        const case = try self.pushNode(.caseBlock, start);

        var header: NodeId = cy.NullNode;
        if (!isElse) {
            header = try self.pushNode(.caseHeader, start);
            self.ast.setNodeData(header, .{ .caseHeader = .{
                .condHead = firstCond,
                .capture = capture,
                .numConds = @intCast(numConds),
            }});
        }

        self.ast.setNodeData(case, .{ .caseBlock = .{
            .header = header,
            .bodyHead = @intCast(bodyHead),
            .bodyIsExpr = bodyExpr,
        }});
        return case;
    }

    fn parseStatement(self: *Parser) anyerror!NodeId {
        var token = self.peek();
        switch (token.tag()) {
            .ident => {
                const token2 = self.peekAhead(1);
                if (token2.tag() == .colon) {
                    // return try self.parseBlock();
                    return self.reportError("Unsupported block statement.", &.{});
                } else {
                    if (try self.parseExprOrAssignStatement()) |id| {
                        return id;
                    }
                }
            },
            .at => {
                const start = self.next_pos;
                _ = start;
                self.advance();
                token = self.peek();

                if (token.tag() == .ident) {
                    return self.reportError("Unsupported @.", &.{});
                } else {
                    return self.reportError("Expected ident after @.", &.{});
                }
            },
            .pound => {
                const start = self.next_pos;
                self.advance();
                token = self.peek();

                if (token.tag() == .ident) {
                    const name = self.ast.src[token.pos()..token.data.end_pos];

                    if (dirModifiers.get(name)) |dir| {
                        const modifier = try self.pushNode(.dirModifier, self.next_pos);
                        self.ast.setNodeData(modifier, .{ .dirModifier = .{
                            .type = dir,
                        }});
                        self.advance();
                        self.consumeWhitespaceTokens();

                        if (self.peek().tag() == .func_k) {
                            return try self.parseFuncDecl(modifier);
                        } else if (self.peek().tag() == .var_k) {
                            return try self.parseVarDecl(modifier, true);
                        } else if (self.peek().tag() == .my_k) {
                            return try self.parseVarDecl(modifier, false);
                        } else if (self.peek().tag() == .type_k) {
                            return try self.parseTypeDecl(modifier, true);
                        } else {
                            return self.reportError("Expected declaration statement.", &.{});
                        }
                    } else {
                        const ident = try self.pushSpanNode(.ident, self.next_pos);
                        self.advance();

                        if (self.peek().tag() != .left_paren) {
                            return self.reportError("Expected ( after ident.", &.{});
                        }

                        const callExpr = try self.parseCallExpression(ident);
                        try self.consumeNewLineOrEnd();

                        const stmt = try self.pushNode(.comptimeStmt, start);
                        self.ast.setNodeData(stmt, .{ .comptimeStmt = .{
                            .expr = callExpr,
                        }});
                        return stmt;
                    }
                } else {
                    return self.reportError("Expected ident after #.", &.{});
                }
            },
            .type_k => {
                return try self.parseTypeDecl(cy.NullNode);
            },
            .func_k => {
                return try self.parseFuncDecl(cy.NullNode);
            },
            .if_k => {
                return try self.parseIfStatement();
            },
            .try_k => {
                if (self.peekAhead(1).tag() == .colon) {
                    return try self.parseTryStmt();
                }
            },
            .switch_k => {
                return try self.parseSwitch(true);
            },
            .for_k => {
                return try self.parseForStatement();
            },
            .while_k => {
                return try self.parseWhileStatement();
            },
            .import_k => {
                return try self.parseImportStmt();
            },
            .pass_k => {
                const id = try self.pushNode(.passStmt, self.next_pos);
                self.advance();
                token = self.peek();
                try self.consumeNewLineOrEnd();
                return id;
            },
            .continue_k => {
                const id = try self.pushNode(.continueStmt, self.next_pos);
                self.advance();
                try self.consumeNewLineOrEnd();
                return id;
            },
            .break_k => {
                const id = try self.pushNode(.breakStmt, self.next_pos);
                self.advance();
                try self.consumeNewLineOrEnd();
                return id;
            },
            .return_k => {
                return try self.parseReturnStatement();
            },
            .var_k => {
                return try self.parseVarDecl(cy.NullNode, true);
            },
            .my_k => {
                return try self.parseVarDecl(cy.NullNode, false);
            },
            else => {},
        }
        if (try self.parseExprOrAssignStatement()) |id| {
            return id;
        }
        self.last_err = try fmt.allocFormat(self.alloc, "unknown token: {} at {}", &.{fmt.v(token.tag()), fmt.v(token.pos())});
        return error.UnknownToken;
    }

    fn reportError(self: *Parser, format: []const u8, args: []const fmt.FmtValue) error{ParseError, FormatError, OutOfMemory} {
        return self.reportErrorAt(format, args, self.next_pos);
    }

    fn reportErrorAt(self: *Parser, format: []const u8, args: []const fmt.FmtValue, tokenPos: u32) error{ParseError, FormatError, OutOfMemory} {
        var srcPos: u32 = undefined;
        if (tokenPos >= self.tokens.len) {
            srcPos = @intCast(self.ast.src.len);
        } else {
            srcPos = self.tokens[tokenPos].pos();
        }
        return self.reportErrorAtSrc(format, args, srcPos);
    }

    fn reportErrorAtSrc(self: *Parser, format: []const u8, args: []const fmt.FmtValue, srcPos: u32) error{ParseError, FormatError, OutOfMemory} {
        self.alloc.free(self.last_err);
        self.last_err = try fmt.allocFormat(self.alloc, format, args);
        self.last_err_pos = srcPos;
        return error.ParseError;
    }

    fn consumeNewLineOrEnd(self: *Parser) !void {
        var tag = self.peek().tag();
        if (tag == .new_line) {
            self.advance();
            return;
        }
        if (tag == .none) {
            return;
        }
        return self.reportError("Expected end of line or file. Got {}.", &.{v(tag)});
    }

    fn consumeWhitespaceTokens(self: *Parser) void {
        var token = self.peek();
        while (token.tag() != .none) {
            switch (token.tag()) {
                .new_line,
                .indent => {
                    self.advance();
                    token = self.peek();
                    continue;
                },
                else => return,
            }
        }
    }

    fn parseSeqDestructure(self: *Parser) !NodeId {
        const start = self.next_pos;
        // Assume first token is left bracket.
        self.advance();

        var lastEntry: NodeId = undefined;
        var firstEntry: NodeId = cy.NullNode;
        var numArgs: u32 = 0;
        outer: {
            self.consumeWhitespaceTokens();
            var token = self.peek();

            if (token.tag() == .right_bracket) {
                // Empty.
                return self.reportError("Expected at least one identifier.", &.{});
            } else {
                firstEntry = (try self.parseExpr(.{})) orelse {
                    return self.reportError("Expected array item.", &.{});
                };
                if (self.ast.nodeType(firstEntry) != .ident) {
                    return self.reportError("Expected ident.", &.{});
                }
                lastEntry = firstEntry;
                numArgs += 1;
            }

            while (true) {
                self.consumeWhitespaceTokens();
                token = self.peek();
                if (token.tag() == .comma) {
                    self.advance();
                    if (self.peek().tag() == .new_line) {
                        self.advance();
                        self.consumeWhitespaceTokens();
                    }
                } else if (token.tag() == .right_bracket) {
                    break :outer;
                }

                token = self.peek();
                if (token.tag() == .right_bracket) {
                    break :outer;
                } else {
                    const ident = (try self.parseExpr(.{})) orelse {
                        return self.reportError("Expected array item.", &.{});
                    };
                    if (self.ast.nodeType(ident) != .ident) {
                        return self.reportError("Expected ident.", &.{});
                    }
                    self.ast.setNextNode(lastEntry, ident);
                    lastEntry = ident;
                    numArgs += 1;
                }
            }
        }

        const seqDestr = try self.pushNode(.seqDestructure, start);
        self.ast.setNodeData(seqDestr, .{ .seqDestructure = .{
            .head = firstEntry,
            .numArgs = @intCast(numArgs),
        }});

        // Parse closing bracket.
        const token = self.peek();
        if (token.tag() == .right_bracket) {
            self.advance();
            return seqDestr;
        } else return self.reportError("Expected closing bracket.", &.{});
    }

    fn parseBracketLiteral(self: *Parser) !NodeId {
        const start = self.next_pos;
        // Assume first token is left bracket.
        self.advance();

        // Check for empty map literal.
        if (self.peek().tag() == .colon) {
            self.advance();
            if (self.peek().tag() != .right_bracket) {
                return self.reportError("Expected closing bracket.", &.{});
            }

            self.advance();
            const record = try self.pushNode(.recordLit, start);
            self.ast.setNodeData(record, .{ .recordLit = .{
                .argHead = cy.NullNode,
                .argTail = cy.NullNode,
                .numArgs = 0,
            }});
            return record;
        } else if (self.peek().tag() == .right_bracket) {
            self.advance();
            const array = try self.pushNode(.arrayLit, start);
            self.ast.setNodeData(array, .{ .arrayLit = .{
                .argHead = cy.NullNode,
                .numArgs = 0,
            }});
            return array;
        }

        // Assume there is at least one argument.

        // If `typeName` is set, then this is a object initializer.
        var typeName: NodeId = cy.NullNode;

        self.consumeWhitespaceTokens();

        const res = try self.parseEmptyTypeInitOrBracketArg();
        if (res.isEmptyTypeInit) {
            // Empty object init. Can assume arg is the type name.
            const dataLit = try self.pushNode(.recordLit, start);
            self.ast.setNodeData(dataLit, .{ .recordLit = .{
                .argHead = cy.NullNode,
                .argTail = cy.NullNode,
                .numArgs = 0,
            }});

            const initN = try self.pushNode(.objectInit, start);
            self.ast.setNodeData(initN, .{ .objectInit = .{
                .name = res.res,
                .initializer = dataLit,
            }});

            return initN;
        }

        var arg = res.res;
        var isRecordArg = res.isRecordArg;

        self.consumeWhitespaceTokens();
        var token = self.peek();
        if (token.tag() == .right_bracket) {
            // One arg literal.
            self.advance();
            if (isRecordArg) {
                const record = try self.pushNode(.recordLit, start);
                self.ast.setNodeData(record, .{ .recordLit = .{
                    .argHead = arg,
                    .argTail = @intCast(arg),
                    .numArgs = 1,
                }});
                return record;
            } else {
                const array = try self.pushNode(.arrayLit, start);
                self.ast.setNodeData(array, .{ .arrayLit = .{
                    .argHead = arg,
                    .numArgs = 1,
                }});
                return array;
            }
        } else if (token.tag() == .comma) {
            // Continue.
        } else {
            if (!isRecordArg) {
                // Assume object initializer. `arg` becomes typename. Parse arg again.
                typeName = arg;
                arg = try self.parseBracketArg(&isRecordArg) orelse return error.Unexpected;
            } else {
                return self.reportError("Expected comma or closing bracket.", &.{});
            }
        }

        const first = arg;
        var last: NodeId = first;
        var numArgs: u32 = 1;
        var isRecord: bool = isRecordArg;

        while (true) {
            self.consumeWhitespaceTokens();
            token = self.peek();
            if (token.tag() == .comma) {
                self.advance();
                if (self.peek().tag() == .new_line) {
                    self.advance();
                    self.consumeWhitespaceTokens();
                }
            } else if (token.tag() == .right_bracket) {
                break;
            } else {
                return self.reportErrorAt("Expected comma or closing bracket.", &.{}, self.next_pos);
            }

            if (try self.parseBracketArg(&isRecordArg)) |entry| {
                // Check that arg kind is the same.
                if (isRecord != isRecordArg) {
                    const argStart = self.ast.nodePos(entry);
                    if (isRecord) {
                        return self.reportErrorAtSrc("Expected key/value pair.", &.{}, argStart);
                    } else {
                        return self.reportErrorAtSrc("Expected data element.", &.{}, argStart);
                    }
                }
                self.ast.setNextNode(last, entry);
                last = entry;
                numArgs += 1;
            } else {
                break;
            }
        }

        // Parse closing bracket.
        if (self.peek().tag() != .right_bracket) {
            return self.reportError("Expected closing bracket.", &.{});
        }
        self.advance();

        if (typeName == cy.NullNode) {
            if (isRecord) {
                const record = try self.pushNode(.recordLit, start);
                self.ast.setNodeData(record, .{ .recordLit = .{
                    .argHead = first,
                    .argTail = @intCast(last),
                    .numArgs = @intCast(numArgs),
                }});
                return record;
            } else {
                const array = try self.pushNode(.arrayLit, start);
                self.ast.setNodeData(array, .{ .arrayLit = .{
                    .argHead = first,
                    .numArgs = @intCast(numArgs),
                }});
                return array;
            }
        } else {
            if (!isRecord) {
                return self.reportError("Expected map literal for object initializer.", &.{});
            }

            const record = try self.pushNode(.recordLit, start);
            self.ast.setNodeData(record, .{ .recordLit = .{
                .argHead = first,
                .argTail = @intCast(last),
                .numArgs = @intCast(numArgs),
            }});

            const initN = try self.pushNode(.objectInit, start);
            self.ast.setNodeData(initN, .{ .objectInit = .{
                .name = typeName,
                .initializer = record,
            }});
            return initN;
        }
    }

    const EmptyTypeInitOrBracketArg = struct {
        res: cy.NodeId,
        isEmptyTypeInit: bool,
        isRecordArg: bool,
    };

    fn parseEmptyTypeInitOrBracketArg(self: *Parser) !EmptyTypeInitOrBracketArg {
        const start = self.next_pos;

        const arg = (try self.parseExpr(.{ .parseShorthandCallExpr = false })) orelse {
            return self.reportError("Expected data argument.", &.{});
        };

        self.consumeWhitespaceTokens();

        if (self.peek().tag() != .colon) {
            return EmptyTypeInitOrBracketArg{
                .res = arg,
                .isEmptyTypeInit = false,
                .isRecordArg = false,
            };
        }
        self.advance();

        self.consumeWhitespaceTokens();
        if (self.peek().tag() == .right_bracket) {
            self.advance();
            return EmptyTypeInitOrBracketArg{
                .res = arg,
                .isEmptyTypeInit = true,
                .isRecordArg = true,
            };
        }

        // Parse key value pair.
        const arg_t = self.ast.nodeType(arg);
        if (!isRecordKeyNodeType(arg_t)) {
            return self.reportError("Expected map key.", &.{});
        }

        const val = (try self.parseExpr(.{})) orelse {
            return self.reportError("Expected map value.", &.{});
        };
        const pair = try self.pushNode(.keyValue, start);
        self.ast.setNodeData(pair, .{ .keyValue = .{
            .key = arg,
            .value = val,
        }});
        return EmptyTypeInitOrBracketArg{
            .res = pair,
            .isEmptyTypeInit = false,
            .isRecordArg = true,
        };
    }

    fn parseBracketArg(self: *Parser, outIsPair: *bool) !?NodeId {
        const start = self.next_pos;

        if (self.peek().tag() == .right_bracket) {
            return null;
        }

        const arg = (try self.parseTightTermExpr()) orelse {
            return self.reportError("Expected data argument.", &.{});
        };

        if (self.peek().tag() != .colon) {
            outIsPair.* = false;
            return arg;
        }
        self.advance();

        // Parse key value pair.
        const arg_t = self.ast.nodeType(arg);
        if (!isRecordKeyNodeType(arg_t)) {
            return self.reportError("Expected map key.", &.{});
        }

        const val = (try self.parseExpr(.{})) orelse {
            return self.reportError("Expected map value.", &.{});
        };
        const pair = try self.pushNode(.keyValue, start);
        self.ast.setNodeData(pair, .{ .keyValue = .{
            .key = arg,
            .value = val,
        }});
        outIsPair.* = true;
        return pair;
    }

    fn parseCallArg(self: *Parser) !?NodeId {
        self.consumeWhitespaceTokens();
        const start = self.next_pos;
        const token = self.peek();
        if (token.tag() == .ident) {
            if (self.peekAhead(1).tag() == .colon) {
                // Named arg.
                const name = try self.pushSpanNode(.ident, start);
                _ = self.consume();
                _ = self.consume();
                var arg = (try self.parseExpr(.{})) orelse {
                    return self.reportError("Expected arg expression.", &.{});
                };
                const namedArg = try self.pushNode(.namedArg, start);
                self.ast.setNodeData(namedArg, .{ .namedArg = .{
                    .name = name,
                    .arg = arg,
                }});
                return namedArg;
            } 
        }

        return try self.parseExpr(.{});
    }

    fn parseAnyCallExpr(self: *Parser, callee: NodeId) !NodeId {
        const token = self.peek();
        if (token.tag() == .left_paren) {
            return try self.parseCallExpression(callee);
        } else {
            return try self.parseNoParenCallExpression(callee);
        }
    }

    fn parseCallExpression(self: *Parser, left_id: NodeId) !NodeId {
        // Assume first token is left paren.
        self.advance();

        const expr_start = self.ast.nodePos(left_id);
        const callExpr = try self.ast.pushNode(self.alloc, .callExpr, expr_start);

        var has_named_arg = false;
        var numArgs: u32 = 0;
        var first: NodeId = cy.NullNode;
        inner: {
            first = (try self.parseCallArg()) orelse {
                break :inner;
            };
            numArgs += 1;
            if (self.ast.nodeType(first) == .namedArg) {
                has_named_arg = true;
            }
            var last_arg_id = first;
            while (true) {
                const token = self.peek();
                if (token.tag() != .comma and token.tag() != .new_line) {
                    break;
                }
                self.advance();
                const arg_id = (try self.parseCallArg()) orelse {
                    break;
                };
                numArgs += 1;
                self.ast.setNextNode(last_arg_id, arg_id);
                last_arg_id = arg_id;
                if (self.ast.nodeType(last_arg_id) == .namedArg) {
                    has_named_arg = true;
                }
            }
        }
        // Parse closing paren.
        self.consumeWhitespaceTokens();
        const token = self.peek();
        if (token.tag() == .right_paren) {
            self.advance();
            self.ast.setNodeData(callExpr, .{ .callExpr = .{
                .callee = @intCast(left_id),
                .argHead = @intCast(first),
                .hasNamedArg = has_named_arg,
                .numArgs = @intCast(numArgs),
            }});
            return callExpr;
        } else return self.reportError("Expected closing parenthesis.", &.{});
    }

    /// Assumes first arg exists.
    fn parseNoParenCallExpression(self: *Parser, left_id: NodeId) !NodeId {
        const expr_start = self.ast.nodePos(left_id);
        const callExpr = try self.ast.pushNode(self.alloc, .callExpr, expr_start);

        const firstArg = (try self.parseTightTermExpr()) orelse {
            return self.reportError("Expected call arg.", &.{});
        };
        var numArgs: u32 = 1;
        var last_arg_id = firstArg;

        while (true) {
            const token = self.peek();
            switch (token.tag()) {
                .new_line => break,
                .none => break,
                else => {
                    const arg = (try self.parseTightTermExpr()) orelse {
                        return self.reportError("Expected call arg.", &.{});
                    };
                    self.ast.setNextNode(last_arg_id, arg);
                    last_arg_id = arg;
                    numArgs += 1;
                },
            }
        }

        self.ast.setNodeData(callExpr, .{ .callExpr = .{
            .callee = @intCast(left_id),
            .argHead = @intCast(firstArg),
            .hasNamedArg = false,
            .numArgs = @intCast(numArgs),
        }});
        return callExpr;
    }

    /// Parses the right expression of a BinaryExpression.
    fn parseRightExpression(self: *Parser, left_op: cy.ast.BinaryExprOp) anyerror!NodeId {
        var start = self.next_pos;
        var token = self.peek();

        switch (token.tag()) {
            .none => {
                return self.reportError("Expected right operand.", &.{});
            },
            .indent,
            .new_line => {
                self.advance();
                self.consumeWhitespaceTokens();
                start = self.next_pos;
                token = self.peek();
                if (token.tag() == .none) {
                    return self.reportError("Expected right operand.", &.{});
                }
            },
            else => {},
        }

        const expr_id = try self.parseTermExpr();

        // Check if next token is an operator with higher precedence.
        token = self.peek();

        var rightOp: cy.ast.BinaryExprOp = undefined;
        switch (token.tag()) {
            .operator => rightOp = toBinExprOp(token.data.operator_t),
            .and_k => rightOp = .and_op,
            .or_k => rightOp = .or_op,
            else => return expr_id,
        }

        const op_prec = getBinOpPrecedence(left_op);
        const right_op_prec = getBinOpPrecedence(rightOp);
        if (right_op_prec > op_prec) {
            // Continue parsing right.
            _ = self.consume();
            start = self.next_pos;
            const right_id = try self.parseRightExpression(rightOp);

            const binExpr = try self.pushNode(.binExpr, start);
            self.ast.setNodeData(binExpr, .{ .binExpr = .{
                .left = expr_id,
                .right = @intCast(right_id),
                .op = rightOp,
            }});

            // Before returning the expr, perform left recursion if the op prec greater than the starting op.
            // eg. a + b * c * d
            //         ^ parseRightExpression starts here
            // Returns ((b * c) * d).
            // eg. a < b * c - d
            //         ^ parseRightExpression starts here
            // Returns ((b * c) - d).
            var left = binExpr;
            while (true) {
                token = self.peek();

                var rightOp2: cy.ast.BinaryExprOp = undefined;
                switch (token.tag()) {
                    .operator => rightOp2 = toBinExprOp(token.data.operator_t),
                    .and_k => rightOp2 = .and_op,
                    .or_k => rightOp2 = .or_op,
                    else => return left,
                }
                const right2_op_prec = getBinOpPrecedence(rightOp2);
                if (right2_op_prec > op_prec) {
                    self.advance();
                    const rightExpr = try self.parseRightExpression(rightOp);
                    const newBinExpr = try self.pushNode(.binExpr, start);
                    self.ast.setNodeData(newBinExpr, .{ .binExpr = .{
                        .left = left,
                        .right = @intCast(rightExpr),
                        .op = rightOp2,
                    }});
                    left = newBinExpr;
                    continue;
                } else {
                    return left;
                }
            }
        }
        return expr_id;
    }

    fn isVarDeclaredFromScope(self: *Parser, name: []const u8) bool {
        var i = self.blockStack.items.len;
        while (i > 0) {
            i -= 1;
            if (self.blockStack.items[i].vars.contains(name)) {
                return true;
            }
        }
        return false;
    }

    fn parseCondExpr(self: *Parser, cond: NodeId, start: u32) !NodeId {
        // Assume `?`.
        self.advance();

        const res = try self.pushNode(.condExpr, start);

        const body = (try self.parseExpr(.{})) orelse {
            return self.reportError("Expected conditional true expression.", &.{});
        };

        const ifBranch = try self.pushNode(.ifBranch, start);
        self.ast.setNodeData(ifBranch, .{ .ifBranch = .{
            .cond = cond,
            .bodyHead = body,
        }});

        self.ast.setNodeData(res, .{ .condExpr = .{
            .ifBranch = ifBranch,
            .elseExpr = cy.NullNode,
        }});

        const token = self.peek();
        if (token.tag() == .else_k) {
            self.advance();

            const elseExpr = (try self.parseExpr(.{})) orelse {
                return self.reportError("Expected else body.", &.{});
            };
            self.ast.nodePtr(res).data.condExpr.elseExpr = elseExpr;
        }
        return res;
    }

    /// A string template begins and ends with .templateString token.
    /// Inside the template, two template expressions can be adjacent to each other.
    fn parseStringTemplate(self: *Parser) !NodeId {
        const start = self.next_pos;

        const id = try self.pushNode(.stringTemplate, start);

        var firstString: NodeId = undefined;
        var token = self.peek();
        if (token.tag() == .templateString) {
            firstString = try self.pushSpanNode(.stringLit, start);
        } else return self.reportError("Expected template string or expression.", &.{});

        var lastWasStringPart = true;
        var lastString = firstString;
        var firstExpr: NodeId = cy.NullNode;
        var lastExpr: NodeId = cy.NullNode;

        self.advance();
        token = self.peek();

        var numExprs: u32 = 0;
        while (true) {
            const tag = token.tag();
            if (tag == .templateString) {
                if (lastWasStringPart) {
                    // End of this template.
                    break;
                }
                const str = try self.pushSpanNode(.stringLit, self.next_pos);
                self.ast.setNextNode(lastString, str);
                lastString = str;
                lastWasStringPart = true;
            } else if (tag == .templateExprStart) {
                self.advance();
                const expr = (try self.parseExpr(.{})) orelse {
                    return self.reportError("Expected expression.", &.{});
                };
                token = self.peek();
                if (token.tag() != .right_paren) {
                    return self.reportError("Expected right paren.", &.{});
                }
                if (firstExpr == cy.NullNode) {
                    firstExpr = expr;
                } else {
                    self.ast.setNextNode(lastExpr, expr);
                }
                lastExpr = expr;
                lastWasStringPart = false;
                numExprs += 1;
            } else {
                break;
            }
            self.advance();
            token = self.peek();
        }

        self.ast.setNodeData(id, .{ .stringTemplate = .{
            .strHead = @intCast(firstString),
            .exprHead = firstExpr,
            .numExprs = @intCast(numExprs),
        }});
        return id;
    }

    /// An expression term doesn't contain a binary expression at the top.
    fn parseTermExpr(self: *Parser) anyerror!NodeId {
        const start = self.next_pos;
        var token = self.peek();
        switch (token.tag()) {
            // .await_k => {
            //     // Await expression.
            //     const expr_id = try self.pushNode(.await_expr, start);
            //     self.advance();
            //     const term_id = try self.parseTermExpr();
            //     self.nodes.items[expr_id].head = .{
            //         .child_head = term_id,
            //     };
            //     return expr_id;
            // },
            .not_k => {
                self.advance();
                const expr = try self.pushNode(.unary_expr, start);
                const child = try self.parseTermExpr();
                self.ast.setNodeData(expr, .{ .unary = .{
                    .child = child,
                    .op = .not,
                }});
                return expr;
            },
            .throw_k => {
                self.advance();
                const child = try self.parseTermExpr();
                const expr = try self.pushNode(.throwExpr, start);
                self.ast.setNodeData(expr, .{ .throwExpr = .{
                    .child = child,
                }});
                return expr;
            },
            .try_k => {
                self.advance();
                const tryExpr = try self.pushNode(.tryExpr, start);
                const expr = try self.parseTermExpr();

                token = self.peek();
                var catchExpr: cy.NodeId = cy.NullNode;
                if (token.tag() == .catch_k) {
                    self.advance();
                    catchExpr = try self.parseTermExpr();
                }

                self.ast.setNodeData(tryExpr, .{ .tryExpr = .{
                    .expr = expr,
                    .catchExpr = catchExpr,
                }});
                return tryExpr;
            },
            .coresume_k => {
                self.advance();
                const coresume = try self.pushNode(.coresume, start);
                const fiberExpr = try self.parseTermExpr();
                self.ast.setNodeData(coresume, .{ .coresume = .{
                    .child = fiberExpr,
                }});
                return coresume;
            },
            .coyield_k => {
                self.advance();
                const coyield = try self.pushNode(.coyield, start);
                return coyield;
            },
            .coinit_k => {
                self.advance();

                if (self.peek().tag() != .left_paren) {
                    return self.reportError("Expected ( after coinit.", &.{});
                }
                self.advance();

                const callee = (try self.parseCallArg()) orelse {
                    return self.reportError("Expected entry function callee.", &.{});
                };

                var numArgs: u32 = 0;
                var first: NodeId = cy.NullNode;
                if (self.peek().tag() == .comma) {
                    self.advance();
                    inner: {
                        first = (try self.parseCallArg()) orelse {
                            break :inner;
                        };
                        numArgs += 1;
                        var last = first;
                        while (true) {
                            self.consumeWhitespaceTokens();

                            if (self.peek().tag() != .comma) {
                                break;
                            }
                            self.advance();
                            const arg = (try self.parseCallArg()) orelse {
                                break;
                            };
                            numArgs += 1;
                            self.ast.setNextNode(last, arg);
                            last = arg;
                        }
                    }
                }

                self.consumeWhitespaceTokens();
                token = self.peek();
                if (token.tag() != .right_paren) {
                    return self.reportError("Expected closing `)`.", &.{});
                }
                self.advance();

                const callExpr = try self.pushNode(.callExpr, start);
                self.ast.setNodeData(callExpr, .{ .callExpr = .{
                    .callee = @intCast(callee),
                    .argHead = @intCast(first),
                    .hasNamedArg = false,
                    .numArgs = @intCast(numArgs),
                }});

                const coinit = try self.pushNode(.coinit, start);
                self.ast.setNodeData(coinit, .{ .coinit = .{
                    .child = callExpr,
                }});
                return coinit;
            },
            else => {
                return (try self.parseTightTermExpr()) orelse {
                    return self.reportError("Expected term expr. Got: {}.", &.{v(self.peek().tag())});
                };
            },
        }
    }

    /// A tight term expr also doesn't include various top expressions
    /// that are separated by whitespace. eg. coinit <expr>
    fn parseTightTermExpr(self: *Parser) anyerror!?NodeId {
        var start = self.next_pos;
        var token = self.peek();
        var left_id = switch (token.tag()) {
            .ident => b: {
                self.advance();
                const id = try self.pushSpanNode(.ident, start);

                const name_token = self.tokens[start];
                const name = self.ast.src[name_token.pos()..name_token.data.end_pos];
                if (!self.isVarDeclaredFromScope(name)) {
                    try self.deps.put(self.alloc, name, id);
                }

                break :b id;
            },
            .type_k => {
                self.advance();
                const id = try self.pushSpanNode(.ident, start);
                return id;
            },
            .error_k => b: {
                self.advance();
                token = self.peek();
                if (token.tag() == .dot) {
                    // Error symbol literal.
                    self.advance();
                    token = self.peek();
                    if (token.tag() == .ident) {
                        const symbol = try self.pushSpanNode(.ident, self.next_pos);
                        self.advance();
                        const id = try self.pushNode(.errorSymLit, start);
                        self.ast.setNodeData(id, .{ .errorSymLit = .{
                            .symbol = symbol,
                        }});
                        break :b id;
                    } else {
                        return self.reportError("Expected symbol identifier.", &.{});
                    }
                } else {
                    // Becomes an ident.
                    const id = try self.pushSpanNode(.ident, start);
                    break :b id;
                }
            },
            .dot => {
                self.advance();
                const name = (try self.parseOptName()) orelse {
                    return self.reportError("Expected symbol identifier.", &.{});
                };
                self.ast.nodePtr(name).head.type = .symbolLit;
                return name;
            },
            .true_k => {
                self.advance();
                return try self.pushNode(.trueLit, start);
            },
            .false_k => {
                self.advance();
                return try self.pushNode(.falseLit, start);
            },
            .none_k => {
                self.advance();
                return try self.pushNode(.noneLit, start);
            },
            .dec => b: {
                self.advance();
                break :b try self.pushSpanNode(.decLit, start);
            },
            .float => b: {
                self.advance();
                break :b try self.pushSpanNode(.floatLit, start);
            },
            .bin => b: {
                self.advance();
                break :b try self.pushSpanNode(.binLit, start);
            },
            .oct => b: {
                self.advance();
                break :b try self.pushSpanNode(.octLit, start);
            },
            .hex => b: {
                self.advance();
                break :b try self.pushSpanNode(.hexLit, start);
            },
            .rune => b: {
                self.advance();
                break :b try self.pushSpanNode(.runeLit, start);
            },
            .string => b: {
                self.advance();
                break :b try self.pushSpanNode(.stringLit, start);
            },
            .templateString => b: {
                break :b try self.parseStringTemplate();
            },
            .pound => b: {
                self.advance();
                token = self.peek();
                if (token.tag() == .ident) {
                    const ident = try self.pushSpanNode(.ident, self.next_pos);
                    self.advance();
                    const expr = try self.pushNode(.comptimeExpr, start);
                    self.ast.setNodeData(expr, .{ .comptimeExpr = .{
                        .child = ident,
                    }});
                    break :b expr;
                } else {
                    return self.reportError("Expected identifier.", &.{});
                }
            },
            .left_paren => b: {
                _ = self.consume();
                token = self.peek();

                const expr_id = (try self.parseExpr(.{})) orelse {
                    token = self.peek();
                    if (token.tag() == .right_paren) {
                        _ = self.consume();
                    } else {
                        return self.reportError("Expected expression.", &.{});
                    }
                    // Assume empty args for lambda.
                    token = self.peek();
                    if (token.tag() == .equal_greater) {
                        return try self.parseNoParamLambdaFunc();
                    } else {
                        return self.reportError("Unexpected paren.", &.{});
                    }
                };
                token = self.peek();
                if (token.tag() == .right_paren) {
                    _ = self.consume();

                    token = self.peek();
                    if (self.ast.nodeType(expr_id) == .ident and token.tag() == .equal_greater) {
                        return try self.parseLambdaFuncWithParam(expr_id);
                    }

                    const group = try self.pushNode(.group, start);
                    self.ast.setNodeData(group, .{ .group = .{
                        .child = expr_id,
                    }});
                    break :b group;
                } else if (token.tag() == .comma) {
                    self.next_pos = start;
                    return try self.parseLambdaFunction();
                } else {
                    return self.reportError("Expected right parenthesis.", &.{});
                }
            },
            .left_bracket => b: {
                const lit = try self.parseBracketLiteral();
                break :b lit;
            },
            .operator => {
                if (token.data.operator_t == .minus) {
                    self.advance();
                    const expr_id = try self.pushNode(.unary_expr, start);
                    const term_id = try self.parseTermExpr();
                    self.ast.setNodeData(expr_id, .{ .unary = .{
                        .child = term_id,
                        .op = .minus,
                    }});
                    return expr_id;
                } else if (token.data.operator_t == .tilde) {
                    self.advance();
                    const expr_id = try self.pushNode(.unary_expr, start);
                    const term_id = try self.parseTermExpr();
                    self.ast.setNodeData(expr_id, .{ .unary = .{
                        .child = term_id,
                        .op = .bitwiseNot,
                    }});
                    return expr_id;
                } else if (token.data.operator_t == .bang) {
                    self.advance();
                    const expr = try self.pushNode(.unary_expr, start);
                    const child = try self.parseTermExpr();
                    self.ast.setNodeData(expr, .{ .unary = .{
                        .child = child,
                        .op = .not,
                    }});
                    return expr;
                } else return self.reportError("Unexpected operator.", &.{});
            },
            else => {
                return null;
            }
        };

        while (true) {
            const next = self.peek();
            switch (next.tag()) {
                .dot => {
                    // Access expr.
                    self.advance();

                    const right = (try self.parseOptName()) orelse {
                        return self.reportError("Expected ident", &.{});
                    };

                    const expr_id = try self.pushNode(.accessExpr, start);
                    self.ast.setNodeData(expr_id, .{ .accessExpr = .{
                        .left = left_id,
                        .right = right,
                    }});
                    left_id = expr_id;
                },
                .left_bracket => {
                    // index expr, slice expr.
                    self.advance();
                    if (self.peek().tag() == .dot_dot) {
                        // Slice expr, start index omitted.
                        self.advance();
                        const rightRange = (try self.parseExpr(.{})) orelse {
                            return self.reportError("Expected expression.", &.{});
                        };

                        if (self.peek().tag() != .right_bracket) {
                            return self.reportError("Expected right bracket.", &.{});
                        }

                        self.advance();

                        const range = try self.pushNode(.range, start);
                        self.ast.setNodeData(range, .{ .range = .{
                            .start = cy.NullNode,
                            .end = rightRange,
                        }});

                        const expr = try self.pushNode(.sliceExpr, start);
                        self.ast.setNodeData(expr, .{ .sliceExpr = .{
                            .arr = left_id,
                            .range = range,
                        }});
                        left_id = expr;
                        start = self.next_pos;
                        continue;
                    }
                    const index = (try self.parseExpr(.{})) orelse {
                        return self.reportError("Expected index.", &.{});
                    };

                    if (self.peek().tag() == .right_bracket) {
                        // Index expr.
                        self.advance();
                        const expr = try self.pushNode(.indexExpr, start);
                        self.ast.setNodeData(expr, .{ .indexExpr = .{
                            .left = left_id,
                            .right = index,
                        }});
                        left_id = expr;
                        start = self.next_pos;
                    } else if (self.peek().tag() == .dot_dot) {
                        // Slice expr.
                        self.advance();
                        if (self.peek().tag() == .right_bracket) {
                            // End index omitted.
                            self.advance();

                            const range = try self.pushNode(.range, start);
                            self.ast.setNodeData(range, .{ .range = .{
                                .start = index,
                                .end = cy.NullNode,
                            }});

                            const expr = try self.pushNode(.sliceExpr, start);
                            self.ast.setNodeData(expr, .{ .sliceExpr = .{
                                .arr = left_id,
                                .range = range,
                            }});
                            left_id = expr;
                            start = self.next_pos;
                        } else {
                            const right = (try self.parseExpr(.{})) orelse {
                                return self.reportError("Expected end index.", &.{});
                            };
                            if (self.peek().tag() != .right_bracket) {
                                return self.reportError("Expected right bracket.", &.{});
                            }
                            self.advance();

                            const range = try self.pushNode(.range, start);
                            self.ast.setNodeData(range, .{ .range = .{
                                .start = index,
                                .end = right,
                            }});

                            const expr = try self.pushNode(.sliceExpr, start);
                            self.ast.setNodeData(expr, .{ .sliceExpr = .{
                                .arr = left_id,
                                .range = range,
                            }});
                            left_id = expr;
                            start = self.next_pos;
                        }
                    } else {
                        return self.reportError("Expected right bracket.", &.{});                            
                    }
                },
                .left_paren => {
                    const call_id = try self.parseCallExpression(left_id);
                    left_id = call_id;
                },
                .dot_dot,
                .right_bracket,
                .right_paren,
                .right_brace,
                .else_k,
                .catch_k,
                .comma,
                .colon,
                .equal,
                .operator,
                .or_k,
                .and_k,
                .as_k,
                .capture,
                .string,
                .bin,
                .oct,
                .hex,
                .dec,
                .float,
                .if_k,
                .ident,
                .pound,
                .templateString,
                .equal_greater,
                .new_line,
                .none => break,
                else => break,
            }
        }
        return left_id;
    }

    fn returnLeftAssignExpr(self: *Parser, leftId: NodeId, outIsAssignStmt: *bool) !NodeId {
        switch (self.ast.nodeType(leftId)) {
            .accessExpr,
            .indexExpr,
            .ident => {
                outIsAssignStmt.* = true;
                return leftId;
            },
            else => {
                return self.reportError("Expected variable to left of assignment operator.", &.{});
            },
        }
    }

    fn parseBinExpr(self: *Parser, left: NodeId, op: cy.ast.BinaryExprOp) !NodeId {
        const opStart = self.next_pos;
        // Assumes current token is the operator.
        self.advance();

        const right = try self.parseRightExpression(op);
        const expr = try self.pushNode(.binExpr, opStart);
        self.ast.setNodeData(expr, .{ .binExpr = .{
            .left = left,
            .right = @intCast(right),
            .op = op,
        }});
        return expr;
    }

    /// An error can be returned during the expr parsing.
    /// If null is returned instead, no token begins an expression
    /// and the caller can assume next_pos did not change. Instead of reporting
    /// a generic error message, it delegates that to the caller.
    fn parseExpr(self: *Parser, opts: ParseExprOptions) anyerror!?NodeId {
        var start = self.next_pos;
        var token = self.peek();

        var left_id: NodeId = undefined;
        switch (token.tag()) {
            .none => return null,
            .right_paren => return null,
            .right_bracket => return null,
            .indent,
            .new_line => {
                self.advance();
                self.consumeWhitespaceTokens();
                start = self.next_pos;
                token = self.peek();
                if (token.tag() == .none) {
                    return null;
                }
            },
            else => {},
        }
        left_id = try self.parseTermExpr();

        while (true) {
            const next = self.peek();
            switch (next.tag()) {
                .equal_greater => {
                    if (self.ast.nodeType(left_id) == .ident) {
                        // Lambda.
                        return try self.parseLambdaFuncWithParam(left_id);
                    } else {
                        return self.reportError("Unexpected `=>` token", &.{});
                    }
                },
                .equal => {
                    // If left is an accessor expression or identifier, parse as assignment statement.
                    if (opts.returnLeftAssignExpr) {
                        return try self.returnLeftAssignExpr(left_id, opts.outIsAssignStmt);
                    } else {
                        break;
                    }
                },
                .operator => {
                    const op_t = next.data.operator_t;
                    switch (op_t) {
                        .plus,
                        .minus,
                        .star,
                        .slash => {
                            if (self.peekAhead(1).tag() == .equal) {
                                if (opts.returnLeftAssignExpr) {
                                    return try self.returnLeftAssignExpr(left_id, opts.outIsAssignStmt);
                                } else {
                                    break;
                                }
                            }
                        },
                        else => {},
                    }
                    const bin_op = toBinExprOp(op_t);
                    left_id = try self.parseBinExpr(left_id, bin_op);
                },
                .as_k => {
                    const opStart = self.next_pos;
                    self.advance();

                    const typeSpec = (try self.parseOptTypeSpec(false)) orelse {
                        return self.reportError("Expected type specifier.", &.{});
                    };
                    const expr = try self.pushNode(.castExpr, opStart);
                    self.ast.setNodeData(expr, .{ .castExpr = .{
                        .expr = left_id,
                        .typeSpec = typeSpec,
                    }});
                    left_id = expr;
                },
                .and_k => {
                    left_id = try self.parseBinExpr(left_id, .and_op);
                },
                .or_k => {
                    left_id = try self.parseBinExpr(left_id, .or_op);
                },
                .question => {
                    left_id = try self.parseCondExpr(left_id, start);
                },
                .right_bracket,
                .right_paren,
                .right_brace,
                .else_k,
                .comma,
                .colon,
                .minusDotDot,
                .dot_dot,
                .capture,
                .new_line,
                .none => break,
                else => {
                    if (!opts.parseShorthandCallExpr) {
                        return left_id;
                    }
                    // Attempt to parse as no paren call expr.
                    switch (self.ast.nodeType(left_id)) {
                        .accessExpr,
                        .ident => {
                            return try self.parseNoParenCallExpression(left_id);
                        },
                        else => {
                            return left_id;
                        }
                    }
                }
            }
        }
        return left_id;
    }

    /// Consumes the an expression or a expression block.
    fn parseEndingExpr(self: *Parser) anyerror!cy.NodeId {
        switch (self.peek().tag()) {
            .func_k => {
                return self.parseMultilineLambdaFunction();
            },
            .switch_k => {
                return self.parseSwitch(false);
            },
            else => {
                return (try self.parseExpr(.{})) orelse {
                    return self.reportError("Expected expression.", &.{});
                };
            },
        }
    }

    fn parseVarDecl(self: *Parser, modifierHead: cy.NodeId, typed: bool) !cy.NodeId {
        const start = self.next_pos;
        self.advance();

        const root = self.peek().tag() == .dot;
        if (root) {
            self.advance();
        }

        // Var name.
        const name = (try self.parseOptNamePath()) orelse {
            return self.reportError("Expected local name identifier.", &.{});
        };
        const hasNamePath = self.ast.node(name).next() != cy.NullNode;
        const isStatic = hasNamePath or root;

        var typeSpec: cy.NodeId = cy.NullNode;
        if (typed) {
            typeSpec = (try self.parseOptTypeSpec(false)) orelse cy.NullNode;
        }

        const varSpec = try self.pushNode(.varSpec, start);
        self.ast.setNodeData(varSpec, .{ .varSpec = .{
            .name = name,
            .typeSpec = typeSpec,
        }});
        self.ast.nodePtr(varSpec).head.data = .{ .varSpec = .{ .modHead = @intCast(modifierHead) }};

        var decl: cy.NodeId = undefined;
        if (isStatic) {
            decl = try self.pushNode(.staticDecl, start);
        } else {
            if (modifierHead != cy.NullNode) {
                return self.reportErrorAt("Annotations are not allowed for local var declarations.", &.{}, start);
            }
            decl = try self.pushNode(.localDecl, start);
        }

        var right: cy.NodeId = cy.NullNode;
        inner: {
            var token = self.peek();
            if (token.tag() == .new_line or token.tag() == .none) {
                break :inner;
            }

            if (self.peek().tag() != .equal) {
                return self.reportError("Expected `=` after variable name.", &.{});
            }
            self.advance();

            // Continue parsing right expr.
            right = try self.parseEndingExpr();
        }

        if (isStatic) {
            self.ast.setNodeData(decl, .{ .staticDecl = .{
                .varSpec = varSpec,
                .right = @intCast(right),
                .typed = typed,
                .root = root,
            }});
            try self.staticDecls.append(self.alloc, .{
                .declT = .variable,
                .nodeId = decl,
                .data = undefined,
            });
        } else {
            self.ast.setNodeData(decl, .{ .localDecl = .{
                .varSpec = varSpec,
                .right = @intCast(right),
                .typed = typed,
            }});
        }
        return decl;
    }

    /// Assumes next token is the return token.
    fn parseReturnStatement(self: *Parser) !NodeId {
        const start = self.next_pos;
        self.advance();
        const token = self.peek();
        switch (token.tag()) {
            .new_line,
            .none => {
                return try self.pushNode(.returnStmt, start);
            },
            .func_k => {
                const lambda = try self.parseMultilineLambdaFunction();
                const id = try self.pushNode(.returnExprStmt, start);
                self.ast.setNodeData(id, .{ .returnExprStmt = .{
                    .child = lambda,
                }});
                return id;
            },
            else => {
                const expr = try self.parseExpr(.{}) orelse {
                    return self.reportError("Expected expression.", &.{});
                };
                try self.consumeNewLineOrEnd();

                const id = try self.pushNode(.returnExprStmt, start);
                self.ast.setNodeData(id, .{ .returnExprStmt = .{
                    .child = expr,
                }});
                return id;
            }
        }
    }

    fn parseExprOrAssignStatement(self: *Parser) !?NodeId {
        var is_assign_stmt = false;
        const expr_id = (try self.parseExpr(.{
            .returnLeftAssignExpr = true,
            .outIsAssignStmt = &is_assign_stmt
        })) orelse {
            return null;
        };

        if (is_assign_stmt) {
            var token = self.peek();
            const opStart = self.next_pos;
            const assignTag = token.tag();
            // Assumes next token is an assignment operator: =, +=.
            self.advance();

            const start = self.ast.nodePos(expr_id);
            var assignStmt: NodeId = undefined;

            // Right can be an expr or stmt.
            var right: NodeId = undefined;
            switch (assignTag) {
                .equal => {
                    assignStmt = try self.ast.pushNode(self.alloc, .assignStmt, start);

                    right = try self.parseEndingExpr();
                    self.ast.setNodeData(assignStmt, .{ .assignStmt = .{
                        .left = expr_id,
                        .right = right,
                    }});
                },
                .operator => {
                    const op_t = token.data.operator_t;
                    switch (op_t) {
                        .plus,
                        .minus,
                        .star,
                        .slash => {
                            self.advance();
                            right = (try self.parseExpr(.{})) orelse {
                                return self.reportError("Expected right expression for assignment statement.", &.{});
                            };
                            assignStmt = try self.ast.pushNode(self.alloc, .opAssignStmt, start);
                            self.ast.setNodeData(assignStmt, .{ .opAssignStmt = .{
                                .left = expr_id,
                                .right = @intCast(right),
                                .op = toBinExprOp(op_t),
                            }});
                        },
                        else => fmt.panic("Unexpected operator assignment.", &.{}),
                    }
                },
                else => return self.reportErrorAt("Unsupported assignment operator.", &.{}, opStart),
            }

            const left = self.ast.nodePtr(expr_id);
            if (left.type() == .ident) {
                const name = self.ast.nodeString(left.*);
                const block = &self.blockStack.items[self.blockStack.items.len-1];
                if (self.deps.get(name)) |node_id| {
                    if (node_id == expr_id) {
                        // Remove dependency now that it's recognized as assign statement.
                        _ = self.deps.remove(name);
                    }
                }
                try block.vars.put(self.alloc, name, {});
            }

            if (self.ast.nodeType(right) != .lambda_multi) {
                token = self.peek();
                try self.consumeNewLineOrEnd();
                return assignStmt;
            } else {
                return assignStmt;
            }
        } else {
            const start = self.ast.nodePos(expr_id);
            const id = try self.ast.pushNode(self.alloc, .exprStmt, start);
            self.ast.setNodeData(id, .{ .exprStmt = .{
                .child = expr_id,
            }});

            const token = self.peek();
            if (token.tag() == .new_line) {
                self.advance();
                return id;
            } else if (token.tag() == .none) {
                return id;
            } else return self.reportError("Expected end of line or file", &.{});
        }
    }

    fn pushNode(self: *Parser, node_t: cy.NodeType, start: u32) !NodeId {
        return self.ast.pushNode(self.alloc, node_t, self.tokens[start].pos());
    }

    fn pushSpanNode(self: *Parser, node_t: cy.NodeType, start: u32) !NodeId {
        const token = self.tokens[start];
        return self.ast.pushSpanNode(self.alloc, node_t, token.pos(), token.data.end_pos);
    }

    /// When n=0, this is equivalent to peek.
    inline fn peekAhead(self: Parser, n: u32) Token {
        if (self.next_pos + n < self.tokens.len) {
            return self.tokens[self.next_pos + n];
        } else {
            return Token.init(.none, self.next_pos, .{
                .end_pos = cy.NullNode,
            });
        }
    }

    inline fn peek(self: Parser) Token {
        if (!self.isAtEnd()) {
            return self.tokens[self.next_pos];
        } else {
            return Token.init(.none, self.next_pos, .{
                .end_pos = cy.NullNode,
            });
        }
    }

    inline fn advance(self: *Parser) void {
        self.next_pos += 1;
    }

    inline fn isAtEnd(self: Parser) bool {
        return self.tokens.len == self.next_pos;
    }

    inline fn consume(self: *Parser) Token {
        const token = self.tokens[self.next_pos];
        self.next_pos += 1;
        return token;
    }
};

pub const Result = struct {
    inner: ResultView,
    
    pub fn init(alloc: std.mem.Allocator, view: ResultView) !Result {
        const arr = try view.nodes.clone(alloc);
        const nodes = try alloc.create(std.ArrayListUnmanaged(cy.Node));
        nodes.* = arr;

        const new_src = try alloc.dupe(u8, view.src);

        const deps = try alloc.create(std.StringHashMapUnmanaged(NodeId));
        deps.* = .{};
        var iter = view.deps.iterator();
        while (iter.next()) |entry| {
            const dep = entry.key_ptr.*;
            const offset = @intFromPtr(dep.ptr) - @intFromPtr(view.src.ptr);
            try deps.put(alloc, new_src[offset..offset+dep.len], entry.value_ptr.*);
        }

        return Result{
            .inner = .{
                .has_error = view.has_error,
                .err_msg = try alloc.dupe(u8, view.err_msg),
                .root_id = view.root_id,
                .nodes = nodes,
                .src = new_src,
                .name = try alloc.dupe(u8, view.name),
                .deps = deps,
            },
        };
    }

    pub fn deinit(self: Result, alloc: std.mem.Allocator) void {
        alloc.free(self.inner.err_msg);
        self.inner.nodes.deinit(alloc);
        alloc.destroy(self.inner.nodes);
        alloc.free(self.inner.tokens);
        alloc.free(self.inner.src);
        self.inner.func_decls.deinit(alloc);
        alloc.destroy(self.inner.func_decls);
        alloc.free(self.inner.func_params);
        alloc.free(self.inner.name);
        self.inner.deps.deinit(alloc);
        alloc.destroy(self.inner.deps);
    }
};

/// Result data is not owned.
pub const ResultView = struct {
    root_id: NodeId,
    err_msg: []const u8,
    has_error: bool,
    isTokenError: bool,

    ast: cy.ast.AstView,

    name: []const u8,
    deps: *std.StringHashMapUnmanaged(NodeId),

    pub fn dupe(self: ResultView, alloc: std.mem.Allocator) !Result {
        return try Result.init(alloc, self);
    }

    pub fn assertOnlyOneStmt(self: ResultView, node_id: NodeId) ?NodeId {
        var count: u32 = 0;
        var stmt_id: NodeId = undefined;
        var cur_id = node_id;
        while (cur_id != cy.NullNode) {
            const cur = self.nodes.items[cur_id];
            if (cur.node_t == .at_stmt and cur.head.at_stmt.skip_compile) {
                cur_id = cur.next;
                continue;
            }
            count += 1;
            stmt_id = cur_id;
            if (count > 1) {
                return null;
            }
            cur_id = cur.next;
        }
        if (count == 1) {
            return stmt_id;
        } else return null;
    }
};

fn toBinExprOp(op: cy.tokenizer.OperatorType) cy.ast.BinaryExprOp {
    return switch (op) {
        .plus => .plus,
        .minus => .minus,
        .star => .star,
        .caret => .caret,
        .slash => .slash,
        .percent => .percent,
        .ampersand => .bitwiseAnd,
        .verticalBar => .bitwiseOr,
        .doubleVerticalBar => .bitwiseXor,
        .lessLess => .bitwiseLeftShift,
        .greaterGreater => .bitwiseRightShift,
        .bang_equal => .bang_equal,
        .less => .less,
        .less_equal => .less_equal,
        .greater => .greater,
        .greater_equal => .greater_equal,
        .equal_equal => .equal_equal,
        .bang,
        .tilde => unreachable,
    };
}

pub fn getBinOpPrecedence(op: cy.ast.BinaryExprOp) u8 {
    switch (op) {
        .bitwiseLeftShift,
        .bitwiseRightShift => return 9,

        .bitwiseAnd => return 8,

        .bitwiseXor,
        .bitwiseOr => return 7,

        .caret => return 6,

        .slash,
        .percent,
        .star => {
            return 5;
        },

        .minus,
        .plus => {
            return 4;
        },

        .cast => return 3,

        .greater,
        .greater_equal,
        .less,
        .less_equal,
        .bang_equal,
        .equal_equal => {
            return 2;
        },

        .and_op => return 1,

        .or_op => return 0,

        else => return 0,
    }
}

pub fn getLastStmt(nodes: []const cy.Node, head: NodeId, out_prev: *NodeId) NodeId {
    var prev: NodeId = cy.NullNode;
    var cur_id = head;
    while (cur_id != cy.NullNode) {
        const node = nodes[cur_id];
        if (node.next == cy.NullNode) {
            out_prev.* = prev;
            return cur_id;
        }
        prev = cur_id;
        cur_id = node.next;
    }
    out_prev.* = cy.NullNode;
    return cy.NullNode;
}

test "Parse dependency variables" {
    var parser = try Parser.init(t.alloc);
    defer parser.deinit();

    var res = try parser.parseNoErr(
        \\foo
    , .{});
    try t.eq(res.deps.size, 1);
    try t.eq(res.deps.contains("foo"), true);

    // Assign statement.
    res = try parser.parseNoErr(
        \\foo = 123
        \\foo
    , .{});
    try t.eq(res.deps.size, 0);

    // Function call.
    res = try parser.parseNoErr(
        \\foo()
    , .{});
    try t.eq(res.deps.size, 1);
    try t.eq(res.deps.contains("foo"), true);

    // Function call after declaration.
    res = try parser.parseNoErr(
        \\func foo():
        \\  pass
        \\foo()
    , .{});
    try t.eq(res.deps.size, 0);
}

pub fn logSrcPos(src: []const u8, start: u32, len: u32) void {
    if (start + len > src.len) {
        log.tracev("{s}", .{ src[start..] });
    } else {
        log.tracev("{s}", .{ src[start..start+len] });
    }
}

const ParseExprOptions = struct {
    returnLeftAssignExpr: bool = false,
    outIsAssignStmt: *bool = undefined,
    parseShorthandCallExpr: bool = true,
};

const StaticDeclType = enum {
    variable,
    typeAlias,
    func,
    funcInit,
    import,
    object,
    enumT,
};

pub const StaticDecl = struct {
    declT: StaticDeclType,
    nodeId: cy.NodeId,
    data: union {
        func: *cy.Func,
        sym: *cy.Sym,
    },
};

fn isRecedingIndent(p: *Parser, prevIndent: u32, curIndent: u32, indent: u32) !bool {
    if (indent ^ curIndent < 0x80000000) {
        return indent <= prevIndent;
    } else {
        if (indent == 0) {
            return true;
        } else {
            if (curIndent & 0x80000000 == 0x80000000) {
                return p.reportError("Expected tabs for indentation.", &.{});
            } else {
                return p.reportError("Expected spaces for indentation.", &.{});
            }
        }
    }
}

fn isRecordKeyNodeType(node_t: cy.NodeType) bool {
    switch (node_t) {
        .ident,
        .stringLit,
        .decLit,
        .binLit,
        .octLit,
        .hexLit => {
            return true;
        },
        else => {
            return false;
        }
    }
}

const FirstLastStmt = struct {
    first: NodeId,
    last: NodeId,
};