#!/bin/bash

RULES_OUTPUT_SEPARATOR="|"
RULES_OUTPUT_SPECIAL_SYMBOLS="-+"
RULES_OUTPUT_IDENTIFIER_FIELD_INDEX=0
RULES_OUTPUT_IDENTIFIER_FIELD_TITLE="identifier"
RULES_OUTPUT_OPT_IN_FIELD_INDEX=1
RULES_OUTPUT_OPT_IN_FIELD_TITLE="optin"
RULES_OUTPUT_OPT_IN_FIELD_TRUE="yes"
RULES_OUTPUT_OPT_IN_FIELD_FALSE="no"

RED_COLOR='\033[0;31m'
GREEN_COLOR='\033[0;32m'
YELLOW_COLOR='\033[0;33m'
BOLD_YELLOW_COLOR='\033[1;33m'
NO_COLOR='\033[0m'

function configure_mint {
    if which mint >/dev/null
    then
        local mint_version
        mint_version=$(mint version)
        mint_version=$(tr -d '[:blank:]' <<< "$mint_version")
        mint_version=${mint_version//"Version:"/}
        echo -e "${GREEN_COLOR}Using mint version $mint_version${NO_COLOR}"
    else 
        echo -e "${RED_COLOR}mint is not installed${NO_COLOR}"
        exit 1
    fi

    if [ -z "$CI" ]
    then
        mint bootstrap
    else 
        echo "Assuming Mint is configured on a CI runner."
    fi

    echo -e "${GREEN_COLOR}Using SwiftLint version $(mint run swiftlint version)${NO_COLOR}"
}

function get_swiftlint_rules_trimmed_output {
    local rules_output
    rules_output=$(mint run swiftlint rules)

    local trimmed_rules_output
    trimmed_rules_output=$(tr -d "$1" <<< "$rules_output")
    trimmed_rules_output=$(sed "s/$RULES_OUTPUT_SEPARATOR$RULES_OUTPUT_SEPARATOR/$RULES_OUTPUT_SEPARATOR/g" <<< "$trimmed_rules_output")
    trimmed_rules_output=${trimmed_rules_output:1:$((${#trimmed_rules_output}-2))}

    echo "$trimmed_rules_output"
}

function get_output_page_size {
    local rules_output_lines_array
    IFS=$'\n' read -ra rules_output_lines_array -d $'\0' <<< "$1"

    local trimmed_header_line
    trimmed_header_line="${rules_output_lines_array[0]:1:$((${#rules_output_lines_array[0]}-2))}"

    local rules_output_header_fields_array
    IFS=$RULES_OUTPUT_SEPARATOR read -ra rules_output_header_fields_array <<< "$trimmed_header_line"
    echo ${#rules_output_header_fields_array[@]}
}

function print_tests_error_description {
    echo -e "${RED_COLOR}Actual $1 does not match the expected value.\nYou should manually run \"mint run swiftlint rules\" and update $2 values accordingly.${NO_COLOR}"
}

function test_rules_parser {
    local tests_are_failing
    local raw_splitted_output_array
    IFS=$RULES_OUTPUT_SEPARATOR read -ra raw_splitted_output_array <<< "$1"
    local rules_output_page_size
    rules_output_page_size="$2"

    echo "Running \"mint run swiftlint rules\" parser tests..."

    if [ $((${#raw_splitted_output_array[@]}%rules_output_page_size)) == 0 ]
    then
        echo "1. Output page size: ✅"
    else 
        tests_are_failing=1
        echo "1. Output page size: ⛔"
        echo -e "${RED_COLOR}Actual page size does not match the calculated value.\nYou should manually run \"mint run swiftlint rules\" and update the script accordingly.\nRULES_OUTPUT_SEPARATOR value may be out of date.${NO_COLOR}"
    fi

    if [ "${raw_splitted_output_array[$RULES_OUTPUT_IDENTIFIER_FIELD_INDEX]}" == "$RULES_OUTPUT_IDENTIFIER_FIELD_TITLE" ]
    then
        echo "2. Identifier field index: ✅"
    else 
        tests_are_failing=1
        echo "2. Identifier field index: ⛔"
        print_tests_error_description "identifier field index" "RULES_OUTPUT_IDENTIFIER_FIELD_INDEX and RULES_OUTPUT_IDENTIFIER_FIELD_TITLE"
    fi

    if [ "${raw_splitted_output_array[$RULES_OUTPUT_OPT_IN_FIELD_INDEX]}" == "$RULES_OUTPUT_OPT_IN_FIELD_TITLE" ]
    then
        echo "3. Opt-in field index: ✅"
    else 
        tests_are_failing=1
        echo "3. Opt-in field index: ⛔"
        print_tests_error_description "opt-in field index" "RULES_OUTPUT_OPT_IN_FIELD_INDEX and RULES_OUTPUT_OPT_IN_FIELD_TITLE"
    fi

    if [ -n "$tests_are_failing" ]
    then
        exit 1
    fi
}

function parse_swiftlint_rules {
    local raw_splitted_output_array
    IFS=$RULES_OUTPUT_SEPARATOR read -ra raw_splitted_output_array <<< "$1"
    local rules_output_page_size
    rules_output_page_size="$2"
    raw_splitted_output_array=( "${raw_splitted_output_array[@]:rules_output_page_size}" )

    local rules_info_paged_index
    rules_info_paged_index=0
    declare -a processed_rules_array
    
    while [[ $rules_info_paged_index -lt ${#raw_splitted_output_array[@]} ]]
    do
        if [ "$3" == "opt_in" ]
        then
            if [ "${raw_splitted_output_array[$((rules_info_paged_index+RULES_OUTPUT_OPT_IN_FIELD_INDEX))]}" == "$RULES_OUTPUT_OPT_IN_FIELD_TRUE" ]
            then
                processed_rules_array[${#processed_rules_array[@]}]=${raw_splitted_output_array[$((rules_info_paged_index+RULES_OUTPUT_IDENTIFIER_FIELD_INDEX))]}
            fi
        else
            if [ "${raw_splitted_output_array[$((rules_info_paged_index+RULES_OUTPUT_OPT_IN_FIELD_INDEX))]}" == "$RULES_OUTPUT_OPT_IN_FIELD_FALSE" ]
            then
                processed_rules_array[${#processed_rules_array[@]}]=${raw_splitted_output_array[$((rules_info_paged_index+RULES_OUTPUT_IDENTIFIER_FIELD_INDEX))]}
            fi
        fi
        rules_info_paged_index=$((rules_info_paged_index+rules_output_page_size))
    done

    echo "${processed_rules_array[@]}"
}

function validate_swiftlint_config {
    local config_file_content
    config_file_content=$(tr -d '[:blank:]-' < .swiftlint.yml)
    local config_file_content_array
    IFS=$'\n' read -ra config_file_content_array -d $'\0' <<< "$config_file_content"

    read -ra opt_in_rules_array <<< "$1"
    declare -a unhandled_rules_array

    for rule in "${opt_in_rules_array[@]}"
    do
        if grep -Fxq "$rule" <<< "$config_file_content"
        then
            continue
        else
            unhandled_rules_array[${#unhandled_rules_array[@]}]="$rule"
        fi
    done

    if [ "${#unhandled_rules_array[@]}" == 0 ]
    then
        echo -e "${GREEN_COLOR}The provided config covers all available rules${NO_COLOR} ✅"
    else
        echo -e "\n${YELLOW_COLOR}New rules are available:${NO_COLOR}" 

        for rule in "${unhandled_rules_array[@]}"
        do
            echo -e "${YELLOW_COLOR}- ${rule}${NO_COLOR}"
        done 

        echo -e "${YELLOW_COLOR}Please add them to ${BOLD_YELLOW_COLOR}opt_in_rules${YELLOW_COLOR}/${BOLD_YELLOW_COLOR}analyzer_rules${YELLOW_COLOR} or ${BOLD_YELLOW_COLOR}disabled_rules${YELLOW_COLOR} config sections.${NO_COLOR}"
    fi

    local disabled_rules_line
    for line_index in "${!config_file_content_array[@]}"
    do
        if [[ "${config_file_content_array[$line_index]}" == *"disabled_rules"* ]]
        then
            disabled_rules_line=$line_index
        fi
    done 

    read -ra rules_array <<< "$2"
    local current_line
    declare -a non_opt_in_rules_array

    for rule in "${rules_array[@]}"
    do
        current_line=0

        for line in "${config_file_content_array[@]}"
        do
            if [ "$current_line" == "$disabled_rules_line" ]
            then
                break
            fi

            if [ "$line" == "$rule" ]
            then
                non_opt_in_rules_array[${#non_opt_in_rules_array[@]}]="$rule"
            fi
            current_line=$((current_line+1))
        done
    done

    if [ "${#non_opt_in_rules_array[@]}" == 0 ]
    then
        echo -e "${GREEN_COLOR}No promoted opt-in rules found${NO_COLOR} ✅"
    else
        echo -e "\n${YELLOW_COLOR}The following rules are no longer opt-in:${NO_COLOR}" 

        for rule in "${non_opt_in_rules_array[@]}"
        do
            echo -e "${YELLOW_COLOR}- ${rule}${NO_COLOR}"
        done 

        echo -e "${YELLOW_COLOR}Please remove them from ${BOLD_YELLOW_COLOR}opt_in_rules${YELLOW_COLOR} config section.${NO_COLOR}"
    fi
}

while getopts "tTv" option
do
    case $option in
        "t")
            SHOULD_RUN_TESTS=true
            ;;
        "T")
            SHOULD_RUN_TESTS=true
            SHOULD_SKIP_VALIDATION=true
            ;;
        "v")
            SHOULD_PRINT_DEBUG_INFO=true
            ;;
        *)
            break
            ;;
    esac
done

configure_mint

rules_raw_output=$(get_swiftlint_rules_trimmed_output "[:blank:]$RULES_OUTPUT_SPECIAL_SYMBOLS")
rules_raw_inline_output=$(get_swiftlint_rules_trimmed_output "[:blank:]$RULES_OUTPUT_SPECIAL_SYMBOLS\n")
rules_output_page_size=$(get_output_page_size "$rules_raw_output")
if [ -n "$SHOULD_PRINT_DEBUG_INFO" ]
then
    echo -e "\nline:${LINENO}. Calculated columns count: $rules_output_page_size"
    echo -e "\nline:${LINENO}. Inline rules output excluding \"$RULES_OUTPUT_SPECIAL_SYMBOLS\" (showing first 3000 symbols):\n${rules_raw_inline_output:0:3000}..."
fi

if [ -n "$SHOULD_RUN_TESTS" ]
then
    test_rules_parser "$rules_raw_inline_output" "$rules_output_page_size"
fi

if [ -n "$SHOULD_SKIP_VALIDATION" ]
then
    exit 0
fi

opt_in_rules=$(parse_swiftlint_rules "$rules_raw_inline_output" "$rules_output_page_size" opt_in)
rules=$(parse_swiftlint_rules "$rules_raw_inline_output" "$rules_output_page_size")
if [ -n "$SHOULD_PRINT_DEBUG_INFO" ]
then
    echo -e "\nline:${LINENO}. Found opt-in rule identifiers:\n$opt_in_rules"
    echo -e "\nline:${LINENO}. Found enabled by default rule identifiers:\n$rules\n"
fi

validate_swiftlint_config "$opt_in_rules" "$rules"