using System;
using System.Collections.Generic;
using System.Text.RegularExpressions;

namespace Subsystem;

public static class DumpsysTreeParser
{
    private class Node
    {
        public int Indent { get; set; }
        public string Name { get; set; } = string.Empty;
        public object? Value { get; set; }
        public bool IsKeyValue { get; set; }
        public string RawText { get; set; } = string.Empty;
        public List<Node> Children { get; } = new();
    }

    public static Dictionary<string, object> Parse(string rawText)
    {
        var lines = rawText.Split(new[] { "\r\n", "\r", "\n" }, StringSplitOptions.RemoveEmptyEntries);
        var root = new Node { Indent = -1, Name = "Root" };
        var stack = new Stack<Node>();
        stack.Push(root);

        var indentRegex = new Regex("^(\\s*)");
        var kvRegex = new Regex("^([^=:]+?)\\s*[:=]\\s*(.*)$");

        foreach (var line in lines)
        {
            if (string.IsNullOrWhiteSpace(line)) continue;

            var indentMatch = indentRegex.Match(line);
            int indent = indentMatch.Success ? indentMatch.Groups[1].Value.Length : 0;
            string trimmed = line.Trim();

            string name = trimmed;
            object? value = null;
            bool isKeyValue = false;

            var kvMatch = kvRegex.Match(trimmed);
            if (kvMatch.Success)
            {
                name = kvMatch.Groups[1].Value.Trim();
                value = kvMatch.Groups[2].Value.Trim();
                isKeyValue = true;
            }

            var node = new Node
            {
                Indent = indent,
                Name = name,
                Value = value,
                IsKeyValue = isKeyValue,
                RawText = trimmed
            };

            while (stack.Count > 0 && stack.Peek().Indent >= indent)
            {
                stack.Pop();
            }

            if (stack.Count > 0)
            {
                stack.Peek().Children.Add(node);
            }

            stack.Push(node);
        }

        return BuildOutputNode(root) as Dictionary<string, object> ?? new Dictionary<string, object>();
    }

    private static object BuildOutputNode(Node n)
    {
        if (n.Children.Count == 0)
        {
            return n.IsKeyValue ? (n.Value ?? "") : n.RawText;
        }

        // Check if all children have no sub-children and are NOT key-values (a simple string list)
        bool isSimpleList = true;
        foreach (var child in n.Children)
        {
            if (child.Children.Count > 0 || child.IsKeyValue)
            {
                isSimpleList = false;
                break;
            }
        }

        if (isSimpleList)
        {
            var list = new List<string>();
            foreach (var child in n.Children)
            {
                list.Add(child.RawText);
            }
            return list.ToArray();
        }

        // Build as a nested dictionary
        var dict = new Dictionary<string, object>(StringComparer.OrdinalIgnoreCase);
        foreach (var child in n.Children)
        {
            object childVal = BuildOutputNode(child);
            string childKey = child.Children.Count > 0 ? child.RawText.TrimEnd(':') : child.Name;

            if (dict.TryGetValue(childKey, out var existing))
            {
                if (existing is List<object> list)
                {
                    list.Add(childVal);
                }
                else
                {
                    var newList = new List<object> { existing, childVal };
                    dict[childKey] = newList;
                }
            }
            else
            {
                dict[childKey] = childVal;
            }
        }
        return dict;
    }
}
