package mesapp;

import java.util.Scanner;
import java.io.IOException;

/**
 * User interface to the Mesapp application.
 * Provides a TUI menu to perform different actions as different user roles.
 */
public class Main {
    private static String currentUser;
    private static String currentRole;
    private static String currentEmail;

    // ID counter for new registrations until interface is hooked onto a real database
    private static int nextUserId = 1;

    /** Maximum number of wrong user attempts when choosing any menu option. */
    private static final int MAX_ATTEMPTS = 3;

    /**
     * Reads a password with asterisk masking.
     * Follows the exact required logic: private candidate string, backspace handling, append char, print asterisks.
     */
    private static String readMaskedPassword(String prompt) {
        System.out.print(prompt);
        StringBuilder password = new StringBuilder();
        
        try {
            while (true) {
                int ch = System.in.read();
                
                if (ch == -1) break; // EOF
                
                char c = (char) ch;
                
                if (c == '\n' || c == '\r') {
                    System.out.println(); // New line after Enter
                    break;
                } 
                else if (c == '\b' || c == 127) { // Backspace or Delete
                    if (password.length() > 0) {
                        password.deleteCharAt(password.length() - 1);
                        // Redraw asterisks
                        redrawAsterisks(password.length());
                    }
                } 
                else if (!Character.isISOControl(c)) { // Regular character
                    password.append(c);
                    // Redraw asterisks
                    redrawAsterisks(password.length());
                }
                // Ignore other control characters
            }
        } catch (IOException e) {
            System.out.println("\nError reading input.");
        }
        
        return password.toString();
    }

    /**
     * Helper to redraw asterisks according to current password length.
     */
    private static void redrawAsterisks(int length) {
        // Move cursor back to start of password area
        System.out.print("\r" + " ".repeat(80) + "\r"); // Clear line (80 chars should be enough)
        System.out.print("*".repeat(length));
        System.out.flush();
    }

    // ===================================================================

    public static void main(String[] args) {
        while (currentUser == null) {
            boolean register = initialMenu();
            if (register) registerMenu();
            else loginMenu();
        }

        if (currentUser != null) actionsMenu();
    }

    private static boolean initialMenu() {
        Scanner sc = new Scanner(System.in);
        String error = null;

        while (true) {
            clearScreen();
            System.out.println("### WELCOME TO MESAPP! ###\n");

            if (error != null) {
                System.out.println("Error: " + error + "\n");
                error = null;
            }

            System.out.println("Choose an option:");
            System.out.println("1. Register a new user");
            System.out.println("2. Log into an existing account");
            userPrompt();

            try {
                int choice = sc.nextInt();
                sc.nextLine();

                switch (choice) {
                    case 1: return true;
                    case 2: return false;
                    default: error = "Invalid choice. Please pick a valid option.";
                }
            } catch (Exception e) {
                error = "Invalid input. Please enter a number.";
                sc.nextLine();
            }
        }
    }

    private static void registerMenu() {
        Scanner sc = new Scanner(System.in);
        int remainingAttempts = MAX_ATTEMPTS;

        clearScreen();
        System.out.println("### REGISTER MENU ###\n");

        // Username
        String username;
        while (true) {
            System.out.print("Choose a username: ");
            username = sc.nextLine().trim();

            if (username.isEmpty()) {
                System.out.println("ERROR: Username cannot be empty.");
            } else {
                break;
            }
        }

        // Email
        String email;
        while (true) {
            System.out.print("Enter your email: ");
            email = sc.nextLine().trim();

            if (email.isEmpty()) {
                System.out.println("ERROR: Email cannot be empty.");
            } else {
                break;
            }
        }

        // Password with masking
        String password;
        while (true) {
            String uncheckedPassword = readMaskedPassword("Choose a password: ");

            if (uncheckedPassword.isEmpty()) {
                System.out.println("ERROR: Password cannot be empty.");
                continue;
            }

            System.out.print("Confirm password: ");
            String confirm = readMaskedPassword("");  // reuse the same masked reader

            if (!uncheckedPassword.equals(confirm)) {
                remainingAttempts--;
                if (remainingAttempts > 0) {
                    System.out.println("ERROR: Passwords do not match.");
                } else {
                    System.out.print("ERROR: Too many failed attempts. Press Enter to continue...");
                    sc.nextLine();
                    return;
                }
            } else {
                password = uncheckedPassword;
                break;
            }
        }

        currentUser = username;
        currentRole = "Client";
        currentEmail = email;

        System.out.println("\nRegistration successful!\n");
        System.out.println("Authenticated as " + currentUser + " [" + currentRole + "].");
    }

    private static void loginMenu() {
        Scanner sc = new Scanner(System.in);
        int remainingAttempts = MAX_ATTEMPTS;

        clearScreen();
        System.out.println("### LOGIN MENU ###\n");

        while (true) {
            System.out.print("Username: ");
            String username = sc.nextLine().trim();
            
            String password = readMaskedPassword("Password: ");

            // TODO: authenticate against database
            remainingAttempts--;

            if (remainingAttempts > 0) {
                System.out.println("ERROR: Incorrect username or password. Please try again");
            } else {
                System.out.print("ERROR: Too many failed attempts. Press Enter to continue...");
                sc.nextLine();
                return;
            }
        }
    }

    private static void actionsMenu() {
        // ... (unchanged - omitted for brevity)
        // Note: changePassword() also needs updating
    }

    private static void changePassword() {
        Scanner sc = new Scanner(System.in);
        clearScreen();

        // Current password
        while (true) {
            String currentPass = readMaskedPassword("Current password: ");
            if (currentPass.isEmpty()) {
                System.out.println("Password cannot be empty.");
                continue;
            } else {
                // TODO: verify against database
                break;
            }
        }

        // New password
        while (true) {
            String newPass = readMaskedPassword("New password: ");

            if (newPass.isEmpty()) {
                System.out.println("Error: Password cannot be empty.");
                continue;
            }

            String newPassConfirm = readMaskedPassword("Confirm new password: ");

            if (!newPass.equals(newPassConfirm)) {
                System.out.println("Error: Passwords do not match. Please try again.");
            } else {
                break;
            }
        }

        System.out.println("Password updated.");
    }

    // ... rest of your methods (actionsClient, actionsWaiter, etc.) remain unchanged

    private static void userPrompt() {
        System.out.print("> ");
    }

    private static void clearScreen() {
        System.out.print("\033[H\033[2J");
        System.out.flush();
    }
}
